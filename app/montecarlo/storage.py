"""Result delivery through OCI Workload Identity or stdout for local testing."""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from typing import Any


def _object_name(result: dict[str, Any]) -> str:
    prefix = os.getenv("OCI_OBJECT_STORAGE_PREFIX", "monte-carlo")
    run_id = str(result["run_id"])
    partition = result["partition"]
    return f"{prefix.rstrip('/')}/runs/{run_id}/partials/part-{partition['index']:05d}.json"


def _stable_partial_fields(result: dict[str, Any]) -> dict[str, Any]:
    """Return fields that must match when a retry finds a write-once result."""
    excluded = {"completed_at", "elapsed_seconds", "result_uri"}
    return {key: value for key, value in result.items() if key not in excluded}


def write_result(result: dict[str, Any]) -> str:
    """Write one partial result without reading user credentials inside a pod."""
    result["completed_at"] = datetime.now(UTC).isoformat()
    serialized = json.dumps(result, sort_keys=True, separators=(",", ":")).encode("utf-8")
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
