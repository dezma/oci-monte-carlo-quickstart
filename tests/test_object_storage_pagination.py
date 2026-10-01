import json
import sys
from types import SimpleNamespace

import pytest
from montecarlo.aggregate import fetch_partials


def test_fetch_partials_uses_list_objects_start_continuation(monkeypatch) -> None:
    calls: dict[str, object] = {"list": [], "get": []}
    signer = object()
    pages = [
        SimpleNamespace(
            objects=[SimpleNamespace(name="prefix/part-00002.json")],
            next_start_with="prefix/part-00003.json",
        ),
        SimpleNamespace(
            objects=[SimpleNamespace(name="prefix/part-00001.json")],
            next_start_with=None,
        ),
    ]

    class FakeClient:
        def __init__(self, config, signer) -> None:
            calls["config"] = config
            calls["signer"] = signer

        def list_objects(self, namespace, bucket, **kwargs):
            calls["list"].append((namespace, bucket, kwargs))
            return SimpleNamespace(data=pages.pop(0))

        def get_object(self, namespace, bucket, name):
            calls["get"].append((namespace, bucket, name))
            body = json.dumps({"name": name}).encode("utf-8")
            return SimpleNamespace(data=SimpleNamespace(content=body))

    fake_oci = SimpleNamespace(
        auth=SimpleNamespace(
            signers=SimpleNamespace(InstancePrincipalsSecurityTokenSigner=lambda: signer)
        ),
        object_storage=SimpleNamespace(ObjectStorageClient=FakeClient),
    )
    monkeypatch.setitem(sys.modules, "oci", fake_oci)
    monkeypatch.setenv("OCI_CLI_AUTH", "instance_principal")
    monkeypatch.setenv("OCI_REGION", " ")
    monkeypatch.setenv("REGION", "eu-frankfurt-1")

    partials = fetch_partials("results", "namespace", "prefix/")

    assert calls["config"] == {"region": "eu-frankfurt-1"}
    assert calls["signer"] is signer
    assert calls["list"] == [
        ("namespace", "results", {"prefix": "prefix/"}),
        (
            "namespace",
            "results",
            {"prefix": "prefix/", "start": "prefix/part-00003.json"},
        ),
    ]
    assert calls["get"] == [
        ("namespace", "results", "prefix/part-00001.json"),
        ("namespace", "results", "prefix/part-00002.json"),
    ]
    assert partials == [
        {"name": "prefix/part-00001.json"},
        {"name": "prefix/part-00002.json"},
    ]


def test_fetch_partials_requires_region_for_instance_principal(monkeypatch) -> None:
    monkeypatch.setenv("OCI_CLI_AUTH", "instance_principal")
    monkeypatch.delenv("OCI_REGION", raising=False)
    monkeypatch.delenv("REGION", raising=False)
    monkeypatch.setitem(sys.modules, "oci", SimpleNamespace())

    try:
        fetch_partials("results", "namespace", "prefix/")
    except ValueError as error:
        assert "OCI_REGION or REGION is required" in str(error)
    else:
        raise AssertionError("expected an explicit region error")


def test_fetch_partials_follows_continuation_after_empty_page(monkeypatch) -> None:
    signer = object()
    pages = [
        SimpleNamespace(objects=[], next_start_with="prefix/next"),
        SimpleNamespace(
            objects=[SimpleNamespace(name="prefix/part-00001.json")],
            next_start_with=None,
        ),
    ]
    list_calls: list[dict[str, str]] = []

    class FakeClient:
        def __init__(self, config, signer) -> None:
            pass

        def list_objects(self, namespace, bucket, **kwargs):
            list_calls.append(kwargs)
            return SimpleNamespace(data=pages.pop(0))

        def get_object(self, namespace, bucket, name):
            return SimpleNamespace(
                data=SimpleNamespace(content=b'{"name":"prefix/part-00001.json"}')
            )

    fake_oci = SimpleNamespace(
        auth=SimpleNamespace(
            signers=SimpleNamespace(InstancePrincipalsSecurityTokenSigner=lambda: signer)
        ),
        object_storage=SimpleNamespace(ObjectStorageClient=FakeClient),
    )
    monkeypatch.setitem(sys.modules, "oci", fake_oci)
    monkeypatch.setenv("OCI_CLI_AUTH", "instance_principal")
    monkeypatch.setenv("REGION", "eu-frankfurt-1")

    assert fetch_partials("results", "namespace", "prefix/") == [
        {"name": "prefix/part-00001.json"}
    ]
    assert list_calls == [
        {"prefix": "prefix/"},
        {"prefix": "prefix/", "start": "prefix/next"},
    ]


def test_fetch_partials_rejects_cyclic_continuations(monkeypatch) -> None:
    signer = object()
    pages = [
        SimpleNamespace(objects=[], next_start_with="prefix/first"),
        SimpleNamespace(objects=[], next_start_with="prefix/second"),
        SimpleNamespace(objects=[], next_start_with="prefix/first"),
    ]

    class FakeClient:
        def __init__(self, config, signer) -> None:
            pass

        def list_objects(self, namespace, bucket, **kwargs):
            return SimpleNamespace(data=pages.pop(0))

    fake_oci = SimpleNamespace(
        auth=SimpleNamespace(
            signers=SimpleNamespace(InstancePrincipalsSecurityTokenSigner=lambda: signer)
        ),
        object_storage=SimpleNamespace(ObjectStorageClient=FakeClient),
    )
    monkeypatch.setitem(sys.modules, "oci", fake_oci)
    monkeypatch.setenv("OCI_CLI_AUTH", "instance_principal")
    monkeypatch.setenv("REGION", "eu-frankfurt-1")

    with pytest.raises(RuntimeError, match="non-advancing list continuation"):
        fetch_partials("results", "namespace", "prefix/")


def test_fetch_partials_deduplicates_repeated_object_names(monkeypatch) -> None:
    signer = object()
    pages = [
        SimpleNamespace(
            objects=[SimpleNamespace(name="prefix/part-00001.json")],
            next_start_with="prefix/part-00001.json",
        ),
        SimpleNamespace(
            objects=[SimpleNamespace(name="prefix/part-00001.json")],
            next_start_with=None,
        ),
    ]
    get_calls: list[str] = []

    class FakeClient:
        def __init__(self, config, signer) -> None:
            pass

        def list_objects(self, namespace, bucket, **kwargs):
            return SimpleNamespace(data=pages.pop(0))

        def get_object(self, namespace, bucket, name):
            get_calls.append(name)
            return SimpleNamespace(data=SimpleNamespace(content=b'{"name":"partial"}'))

    fake_oci = SimpleNamespace(
        auth=SimpleNamespace(
            signers=SimpleNamespace(InstancePrincipalsSecurityTokenSigner=lambda: signer)
        ),
        object_storage=SimpleNamespace(ObjectStorageClient=FakeClient),
    )
    monkeypatch.setitem(sys.modules, "oci", fake_oci)
    monkeypatch.setenv("OCI_CLI_AUTH", "instance_principal")
    monkeypatch.setenv("REGION", "eu-frankfurt-1")

    assert fetch_partials("results", "namespace", "prefix/") == [{"name": "partial"}]
    assert get_calls == ["prefix/part-00001.json"]
