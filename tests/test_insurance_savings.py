import json
from pathlib import Path

import pytest

from montecarlo.insurance import load_insurance_savings_spec, run_insurance_savings_partition
from montecarlo.insurance_aggregate import aggregate_insurance_savings
from montecarlo.spec import SpecError


def _payload() -> dict[str, object]:
    return {
        "workload_type": "insurance_savings",
        "run_id": "test-policy",
        "simulations": 4,
        "seed": 7,
        "confidence_level": 0.95,
        "projection": {"term_years": 1, "steps_per_year": 12, "discount_rate": 0.0},
        "policy": {
            "issue_age": 40,
            "initial_premium": 0.0,
            "monthly_premium": 0.0,
            "premium_payment_years": 0,
            "maturity_guarantee": 200.0,
            "death_benefit": 0.0,
            "surrender_charge_rate": 0.0,
        },
        "fund": {
            "initial_account_value": 100.0,
            "expected_annual_return": 0.0,
            "annual_volatility": 0.0,
            "annual_management_fee": 0.0,
        },
        "policyholder_behavior": {
            "annual_lapse_rate": 0.0,
            "lapse_rate_stress_multiplier": 1.0,
        },
        "mortality": {
            "base_annual_mortality_rate": 0.0,
            "annual_ageing_multiplier": 1.0,
        },
        "expenses": {"monthly_policy_expense": 0.0},
    }


def _spec(tmp_path: Path):
    spec_path = tmp_path / "insurance.json"
    spec_path.write_text(json.dumps(_payload()), encoding="utf-8")
    return load_insurance_savings_spec(spec_path)


def test_insurance_savings_partition_reports_simple_guarantee_cashflows(tmp_path: Path) -> None:
    spec = _spec(tmp_path)

    partial = run_insurance_savings_partition(spec, 0, 1, engine_version="test")

    assert partial.workload_type == "insurance_savings"
    assert partial.simulations == 4
    assert partial.sum_pv_benefits == 800.0
    assert partial.sum_pv_premiums == 0.0
    assert partial.sum_pv_expenses == 0.0
    assert partial.sum_pv_net_liability == 800.0
    assert partial.maturity_count == 4
    assert partial.guarantee_binding_count == 4
    assert partial.surrender_count == 0
    assert partial.death_claim_count == 0


def test_insurance_savings_requires_monthly_projection(tmp_path: Path) -> None:
    payload = _payload()
    projection = payload["projection"]
    assert isinstance(projection, dict)
    projection["steps_per_year"] = 4
    spec_path = tmp_path / "invalid.json"
    spec_path.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(SpecError, match="must be 12"):
        load_insurance_savings_spec(spec_path)


def test_insurance_aggregate_returns_liability_and_outcomes(tmp_path: Path) -> None:
    spec = _spec(tmp_path)
    partials = []
    for index in range(2):
        partial = run_insurance_savings_partition(spec, index, 2, engine_version="test").to_dict()
        partials.append(partial)

    summary = aggregate_insurance_savings(partials, 0.95, expected_partitions=2)

    assert summary["workload_type"] == "insurance_savings"
    assert summary["simulations"] == 4
    assert summary["net_liability"] == 200.0
    assert summary["expected_pv_benefits"] == 200.0
    assert summary["maturity_probability"] == 1.0
    assert summary["guarantee_binding_probability"] == 1.0
    assert summary["surrender_probability"] == 0.0
    assert summary["death_claim_probability"] == 0.0
    assert summary["net_liability_confidence_interval"] == [200.0, 200.0]
