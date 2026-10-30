"""Aggregate synthetic insurance-savings partials on the private operator."""

from __future__ import annotations

import argparse
import json
from math import sqrt
from typing import Any

from .aggregate import _positive_integer, _validate_expected_partitions, _z_score, fetch_partials


def _number(item: dict[str, Any], key: str, partial_number: int) -> float:
    value = item.get(key)
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ValueError(f"partial result {partial_number} has {key} that is not a number")
    return float(value)


def _count(item: dict[str, Any], key: str, partial_number: int) -> int:
    value = item.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(
            f"partial result {partial_number} has {key} that is not a non-negative integer"
        )
    return value


def aggregate_insurance_savings(
    partials: list[dict[str, Any]], confidence: float, expected_partitions: int | None = None
) -> dict[str, Any]:
    """Combine path-level cash-flow moments into a policy-liability summary."""
    if not partials:
        raise ValueError("no partial results were found")
    _validate_expected_partitions(partials, expected_partitions)
    workload_types = {item.get("workload_type") for item in partials}
    run_ids = {item.get("run_id") for item in partials}
    input_hashes = {item.get("input_sha256") for item in partials}
    if workload_types != {"insurance_savings"}:
        raise ValueError("partial results are not all insurance_savings workload results")
    if len(run_ids) != 1 or len(input_hashes) != 1:
        raise ValueError("partial results do not belong to one reproducible run")

    simulations = sum(
        _count(item, "simulations", number) for number, item in enumerate(partials, 1)
    )
    if simulations < 2:
        raise ValueError("at least two simulations are required for a confidence interval")

    def total(key: str) -> float:
        return sum(_number(item, key, number) for number, item in enumerate(partials, 1))

    pv_benefits = total("sum_pv_benefits")
    pv_premiums = total("sum_pv_premiums")
    pv_expenses = total("sum_pv_expenses")
    net_liability = total("sum_pv_net_liability")
    squared_net_liability = total("sum_squared_pv_net_liability")
    maturity_account_value = total("sum_maturity_account_value")
    maturity_count = sum(
        _count(item, "maturity_count", number) for number, item in enumerate(partials, 1)
    )
    guarantee_binding_count = sum(
        _count(item, "guarantee_binding_count", number) for number, item in enumerate(partials, 1)
    )
    surrender_count = sum(
        _count(item, "surrender_count", number) for number, item in enumerate(partials, 1)
    )
    death_claim_count = sum(
        _count(item, "death_claim_count", number) for number, item in enumerate(partials, 1)
    )
    if maturity_count + surrender_count + death_claim_count != simulations:
        raise ValueError("insurance outcome counts do not add up to simulations")
    if guarantee_binding_count > maturity_count:
        raise ValueError("guarantee_binding_count cannot exceed maturity_count")

    mean_net_liability = net_liability / simulations
    variance = max(
        0.0,
        (squared_net_liability - net_liability**2 / simulations) / (simulations - 1),
    )
    standard_error = sqrt(variance / simulations)
    margin = _z_score(confidence) * standard_error
    return {
        "workload_type": "insurance_savings",
        "run_id": next(iter(run_ids)),
        "input_sha256": next(iter(input_hashes)),
        "partitions": len(partials),
        "simulations": simulations,
        "expected_pv_benefits": pv_benefits / simulations,
        "expected_pv_premiums": pv_premiums / simulations,
        "expected_pv_expenses": pv_expenses / simulations,
        "net_liability": mean_net_liability,
        "net_liability_sample_standard_deviation": sqrt(variance),
        "net_liability_standard_error": standard_error,
        "confidence_level": confidence,
        "net_liability_confidence_interval": [
            mean_net_liability - margin,
            mean_net_liability + margin,
        ],
        "expected_maturity_account_value": (
            maturity_account_value / maturity_count if maturity_count else None
        ),
        "maturity_probability": maturity_count / simulations,
        "guarantee_binding_probability": guarantee_binding_count / simulations,
        "surrender_probability": surrender_count / simulations,
        "death_claim_probability": death_claim_count / simulations,
        "total_worker_seconds": sum(
            _number(item, "elapsed_seconds", number) for number, item in enumerate(partials, 1)
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate synthetic insurance-savings partial results from OCI Object Storage."
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
    summary = aggregate_insurance_savings(
        fetch_partials(arguments.bucket, arguments.namespace, arguments.prefix),
        arguments.confidence,
        expected_partitions=arguments.expected_partitions,
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
