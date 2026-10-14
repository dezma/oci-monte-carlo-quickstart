import json
import sys
from types import SimpleNamespace

import pytest
from montecarlo.storage import write_result


def _result() -> dict[str, object]:
    return {
        "run_id": "test-run",
        "partition": {"index": 0},
        "input_sha256": "a" * 64,
        "engine_version": "test",
    }


def test_write_result_configures_object_storage_client_region(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: dict[str, object] = {}
    signer = object()

    class FakeClient:
        def __init__(self, config: dict[str, str], signer: object) -> None:
            calls["config"] = config
            calls["signer"] = signer

        def put_object(self, **kwargs: object) -> None:
            calls["put_object"] = kwargs

    fake_oci = SimpleNamespace(
        auth=SimpleNamespace(
            signers=SimpleNamespace(
                get_oke_workload_identity_resource_principal_signer=lambda: signer
            )
        ),
        object_storage=SimpleNamespace(ObjectStorageClient=FakeClient),
    )
    monkeypatch.setitem(sys.modules, "oci", fake_oci)
    monkeypatch.setenv("OCI_OBJECT_STORAGE_BUCKET", "results")
    monkeypatch.setenv("OCI_OBJECT_STORAGE_NAMESPACE", "namespace")
    monkeypatch.setenv("OCI_OBJECT_STORAGE_PREFIX", "monte-carlo")
    monkeypatch.setenv("OCI_REGION", "eu-frankfurt-1")

    uri = write_result(_result())

    assert calls["config"] == {"region": "eu-frankfurt-1"}
    assert calls["signer"] is signer
    assert uri == "oci://results/monte-carlo/runs/test-run/partials/part-00000.json"


def test_write_result_requires_region_for_object_storage(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OCI_OBJECT_STORAGE_BUCKET", "results")
    monkeypatch.setenv("OCI_OBJECT_STORAGE_NAMESPACE", "namespace")
    monkeypatch.delenv("OCI_REGION", raising=False)

    with pytest.raises(ValueError, match="OCI_REGION is required"):
        write_result(_result())


def test_write_result_accepts_matching_immutable_result_from_retry(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    result = _result()
    result["elapsed_seconds"] = 0.1
    result["completed_at"] = "2026-10-05T00:00:00+00:00"
    existing = {**result, "elapsed_seconds": 9.9, "completed_at": "2026-10-05T00:01:00+00:00"}

    class PreconditionFailed(Exception):
        status = 412

    class FakeClient:
        def __init__(self, config: dict[str, str], signer: object) -> None:
            pass

        def put_object(self, **kwargs: object) -> None:
            raise PreconditionFailed()

        def get_object(self, *args: object) -> object:
            return SimpleNamespace(
                data=SimpleNamespace(content=json.dumps(existing).encode("utf-8"))
            )

    fake_oci = SimpleNamespace(
        auth=SimpleNamespace(
            signers=SimpleNamespace(
                get_oke_workload_identity_resource_principal_signer=lambda: object()
            )
        ),
        object_storage=SimpleNamespace(ObjectStorageClient=FakeClient),
    )
    monkeypatch.setitem(sys.modules, "oci", fake_oci)
    monkeypatch.setenv("OCI_OBJECT_STORAGE_BUCKET", "results")
    monkeypatch.setenv("OCI_OBJECT_STORAGE_NAMESPACE", "namespace")
    monkeypatch.setenv("OCI_REGION", "eu-frankfurt-1")

    assert write_result(result) == "oci://results/monte-carlo/runs/test-run/partials/part-00000.json"
