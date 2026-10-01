"""Aggregate immutable partial results from Object Storage on the private operator."""

from __future__ import annotations

import argparse
import json
import os
from math import sqrt
from typing import Any

Z_SCORES = {0.90: 1.6448536269, 0.95: 1.9599639845, 0.99: 2.5758293035}


def _positive_integer(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _instance_principal_region() -> str:
    for variable in ("OCI_REGION", "REGION"):
        region = (os.getenv(variable) or "").strip()
        if region:
            return region
    return ""


def _z_score(confidence: float) -> float:
    try:
        return Z_SCORES[round(confidence, 2)]
    except KeyError as error:
        supported = ", ".join(str(level) for level in sorted(Z_SCORES))
        raise ValueError(f"confidence must be one of {supported}") from error


def _require_partition_integer(
    partition: dict[str, Any], key: str, partial_number: int
) -> int:
    value = partition.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(
            f"partial result {partial_number} has a partition.{key} that is not an integer"
        )
    return value


def _validate_expected_partitions(
    partials: list[dict[str, Any]], expected_partitions: int | None
) -> None:
    """Ensure an aggregate contains every expected Indexed Job result exactly once."""
    if expected_partitions is None:
        return
    if isinstance(expected_partitions, bool) or not isinstance(expected_partitions, int):
        raise ValueError("expected_partitions must be a positive integer")
    if expected_partitions < 1:
        raise ValueError("expected_partitions must be a positive integer")

    observed: dict[int, tuple[int, int, int]] = {}
    for partial_number, partial in enumerate(partials, start=1):
        if not isinstance(partial, dict):
            raise ValueError(f"partial result {partial_number} is not a JSON object")
        partition = partial.get("partition")
        if not isinstance(partition, dict):
            raise ValueError(f"partial result {partial_number} is missing partition metadata")
        index = _require_partition_integer(partition, "index", partial_number)
        count = _require_partition_integer(partition, "count", partial_number)
        start = _require_partition_integer(partition, "start", partial_number)
        size = _require_partition_integer(partition, "size", partial_number)
        simulations = partial.get("simulations")
        if isinstance(simulations, bool) or not isinstance(simulations, int):
            raise ValueError(
                f"partial result {partial_number} has simulations that are not an integer"
            )
        if count != expected_partitions:
            raise ValueError(
                f"partial result {partial_number} has partition.count={count}; "
                f"expected {expected_partitions}"
            )
        if not 0 <= index < expected_partitions:
            raise ValueError(
                f"partial result {partial_number} has partition.index={index}; "
                f"expected an index from 0 to {expected_partitions - 1}"
            )
        if start < 0 or size < 0 or simulations < 0:
            raise ValueError(f"partial result {partial_number} has negative partition metadata")
        if simulations != size:
            raise ValueError(
                f"partial result {partial_number} simulations do not match partition.size"
            )
        if index in observed:
            raise ValueError(f"duplicate partial result for partition index {index}")
        observed[index] = (start, size, simulations)

    missing = sorted(set(range(expected_partitions)) - set(observed))
    if missing:
        missing_text = ", ".join(str(index) for index in missing)
        raise ValueError(f"missing partial results for partition indexes: {missing_text}")

    total_simulations = sum(size for _, size, _ in observed.values())
    base, remainder = divmod(total_simulations, expected_partitions)
    for index, (start, size, _) in observed.items():
        expected_size = base + (1 if index < remainder else 0)
        expected_start = index * base + min(index, remainder)
        if start != expected_start or size != expected_size:
            raise ValueError(
                f"partial result for partition index {index} does not match the expected "
                "non-overlapping partition layout"
            )


def aggregate(
    partials: list[dict[str, Any]], confidence: float, expected_partitions: int | None = None
) -> dict[str, Any]:
    """Combine additive moments from independent deterministic partitions."""
    if not partials:
        raise ValueError("no partial results were found")
    _validate_expected_partitions(partials, expected_partitions)
    run_ids = {item["run_id"] for item in partials}
    input_hashes = {item["input_sha256"] for item in partials}
    if len(run_ids) != 1 or len(input_hashes) != 1:
        raise ValueError("partial results do not belong to one reproducible run")

    simulations = sum(int(item["simulations"]) for item in partials)
    if simulations < 2:
        raise ValueError("at least two simulations are required for a confidence interval")
    payoff_sum = sum(float(item["sum_discounted_payoff"]) for item in partials)
    squared_sum = sum(float(item["sum_squared_discounted_payoff"]) for item in partials)
    mean = payoff_sum / simulations
    variance = max(0.0, (squared_sum - payoff_sum**2 / simulations) / (simulations - 1))
    standard_error = sqrt(variance / simulations)
    margin = _z_score(confidence) * standard_error
    return {
        "run_id": next(iter(run_ids)),
        "input_sha256": next(iter(input_hashes)),
        "partitions": len(partials),
        "simulations": simulations,
        "price": mean,
        "sample_standard_deviation": sqrt(variance),
        "standard_error": standard_error,
        "confidence_level": confidence,
        "confidence_interval": [mean - margin, mean + margin],
        "total_worker_seconds": sum(float(item["elapsed_seconds"]) for item in partials),
    }


def fetch_partials(bucket: str, namespace: str, prefix: str) -> list[dict[str, Any]]:
    """Read matching result objects using instance principals or local OCI configuration."""
    import oci

    if os.getenv("OCI_CLI_AUTH") == "instance_principal":
        region = _instance_principal_region()
        if not region:
            raise ValueError(
                "OCI_REGION or REGION is required when using an instance principal"
            )
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        client = oci.object_storage.ObjectStorageClient(
            config={"region": region}, signer=signer
        )
    else:
        config = oci.config.from_file()
        client = oci.object_storage.ObjectStorageClient(config)

    names: set[str] = set()
    start: str | None = None
    seen_continuations: set[str] = set()
    while True:
        list_kwargs: dict[str, str] = {"prefix": prefix}
        if start:
            list_kwargs["start"] = start
        response = client.list_objects(namespace, bucket, **list_kwargs)
        names.update(
            item.name
            for item in (response.data.objects or [])
            if item.name.endswith(".json")
        )
        next_start = getattr(response.data, "next_start_with", None)
        if not next_start:
            break
        if not isinstance(next_start, str) or next_start in seen_continuations:
            raise RuntimeError("Object Storage returned a non-advancing list continuation")
        seen_continuations.add(next_start)
        start = next_start

    partials: list[dict[str, Any]] = []
    for name in sorted(names):
        object_response = client.get_object(namespace, bucket, name)
        partials.append(json.loads(object_response.data.content.decode("utf-8")))
    return partials


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate Monte Carlo partial results from OCI Object Storage."
    )
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--confidence", type=float, default=0.95)
    parser.add_argument(
        "--expected-partitions",
        type=_positive_integer,
        help="require exactly this many Indexed Job partition results",
    )
    arguments = parser.parse_args(argv)
    summary = aggregate(
        fetch_partials(arguments.bucket, arguments.namespace, arguments.prefix),
        arguments.confidence,
        expected_partitions=arguments.expected_partitions,
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
