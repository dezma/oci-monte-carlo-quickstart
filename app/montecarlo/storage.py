"""Write immutable simulation partitions to Object Storage, FSS, or stdout."""

from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

_RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
_RESULT_DELIVERY_MODES = {"object_storage", "fss"}


def _object_name(result: dict[str, Any]) -> str:
    prefix = os.getenv("OCI_OBJECT_STORAGE_PREFIX", "monte-carlo")
    run_id = str(result["run_id"])
    partition = result["partition"]
    return f"{prefix.rstrip('/')}/runs/{run_id}/partials/part-{partition['index']:05d}.json"


def _stable_partial_fields(result: dict[str, Any]) -> dict[str, Any]:
    """Return fields that must match when a retry finds a write-once result."""
    excluded = {"completed_at", "elapsed_seconds", "result_uri"}
    return {key: value for key, value in result.items() if key not in excluded}


def _result_delivery_mode() -> str:
    mode = (os.getenv("MCQS_RESULT_DELIVERY_MODE") or "object_storage").strip()
    if mode not in _RESULT_DELIVERY_MODES:
        raise ValueError("MCQS_RESULT_DELIVERY_MODE must be object_storage or fss")
    return mode


def _fss_partial_path(result: dict[str, Any]) -> Path:
    configured_root = (os.getenv("MCQS_FSS_RESULTS_DIR") or "").strip()
    if not configured_root:
        raise ValueError("MCQS_FSS_RESULTS_DIR is required when FSS output is configured")
    run_id = str(result["run_id"])
    if not _RUN_ID_PATTERN.fullmatch(run_id):
        raise ValueError("run_id is unsafe for an FSS result path")
    partition = result["partition"]
    if not isinstance(partition, dict) or not isinstance(partition.get("index"), int):
        raise ValueError("partition.index must be an integer for an FSS result path")
    if partition["index"] < 0:
        raise ValueError("partition.index must not be negative for an FSS result path")

    root = Path(configured_root).resolve(strict=True)
    partial_path = root / "runs" / run_id / "partials" / f"part-{partition['index']:05d}.json"
    # The run ID and partition are validated above; retain this guard so a
    # future path-layout change cannot accidentally escape the mounted export.
    if root not in partial_path.resolve().parents:
        raise ValueError("FSS result path is outside MCQS_FSS_RESULTS_DIR")
    return partial_path


def _read_fss_partial(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"existing immutable FSS result {path} cannot be read") from error


def _write_fss_result(result: dict[str, Any], serialized: bytes) -> str:
    """Publish a result atomically on an FSS mount without overwriting retries."""
    destination = _fss_partial_path(result)
    destination.parent.mkdir(mode=0o2770, parents=True, exist_ok=True)
    # The FSS export maps workers to UID/GID 10001. The directory setgid bit
    # preserves its group so the operator can aggregate results safely.
    try:
        os.chmod(destination.parent, 0o2770)
    except OSError:
        # The directory may have been created by another concurrent partition;
        # opening the final name below remains the write-once authority.
        pass

    file_descriptor, temporary_name = tempfile.mkstemp(
        dir=destination.parent,
        prefix=f".part-{result['partition']['index']:05d}.",
        suffix=".tmp",
        text=False,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(file_descriptor, "wb") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o640)
        try:
            # link(2) is atomic and refuses to replace an existing result. It
            # is supported by NFS and avoids the overwrite race of rename(2).
            os.link(temporary, destination)
        except FileExistsError:
            existing_result = _read_fss_partial(destination)
            if _stable_partial_fields(existing_result) != _stable_partial_fields(result):
                raise RuntimeError(
                    f"immutable FSS result {destination} already exists with different partition content"
                )
        else:
            directory_descriptor = os.open(destination.parent, os.O_DIRECTORY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return f"fss://{destination}"


def write_result(result: dict[str, Any]) -> str:
    """Write one partial result without reading user credentials inside a pod."""
    result["completed_at"] = datetime.now(UTC).isoformat()
    serialized = json.dumps(result, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if _result_delivery_mode() == "fss":
        return _write_fss_result(result, serialized)

    bucket = os.getenv("OCI_OBJECT_STORAGE_BUCKET")
    namespace = os.getenv("OCI_OBJECT_STORAGE_NAMESPACE")
    if not bucket or not namespace:
        print(serialized.decode("utf-8"))
        return "stdout://partial-result"

    import oci  # Imported only when an OCI result target is configured.

    region = (os.getenv("OCI_REGION") or "").strip()
    if not region:
        raise ValueError("OCI_REGION is required when Object Storage output is configured")

    signer = oci.auth.signers.get_oke_workload_identity_resource_principal_signer()
    client = oci.object_storage.ObjectStorageClient(config={"region": region}, signer=signer)
    object_name = _object_name(result)
    try:
        client.put_object(
            namespace_name=namespace,
            bucket_name=bucket,
            object_name=object_name,
            put_object_body=serialized,
            # Enforce write-once partials even though bucket versioning is enabled.
            if_none_match="*",
            content_type="application/json",
            opc_meta={
                "input-sha256": str(result["input_sha256"]),
                "engine-version": str(result["engine_version"]),
            },
        )
    except Exception as error:
        # A pod can be interrupted after Object Storage accepts the write but
        # before it reports success. A retry is safe only if the existing
        # immutable result has the same deterministic partition content.
        if getattr(error, "status", None) != 412:
            raise
        existing = client.get_object(namespace, bucket, object_name)
        existing_result = json.loads(existing.data.content.decode("utf-8"))
        if _stable_partial_fields(existing_result) != _stable_partial_fields(result):
            raise RuntimeError(
                f"immutable result {object_name} already exists with different partition content"
            ) from error
    return f"oci://{bucket}/{object_name}"
