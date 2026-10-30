"""Synthetic savings-policy Monte Carlo workload for technical demonstrations.

This module intentionally models a small, transparent set of policy mechanics.  It
is a cloud-execution example, not an actuarial valuation, product-pricing, or
capital model.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from hashlib import sha256
from math import exp, sqrt
from pathlib import Path
from time import perf_counter
from typing import Any

import numpy as np

from .engine import partition_work
from .spec import SpecError, _require_number


@dataclass(frozen=True)
class Projection:
    term_years: int
    steps_per_year: int
    discount_rate: float


@dataclass(frozen=True)
class Policy:
    issue_age: int
    initial_premium: float
    monthly_premium: float
    premium_payment_years: int
    maturity_guarantee: float
    death_benefit: float
    surrender_charge_rate: float


@dataclass(frozen=True)
class Fund:
    initial_account_value: float
    expected_annual_return: float
    annual_volatility: float
    annual_management_fee: float


@dataclass(frozen=True)
class PolicyholderBehavior:
    annual_lapse_rate: float
    lapse_rate_stress_multiplier: float


@dataclass(frozen=True)
class Mortality:
    base_annual_mortality_rate: float
    annual_ageing_multiplier: float


@dataclass(frozen=True)
class Expenses:
    monthly_policy_expense: float


@dataclass(frozen=True)
class InsuranceSavingsSpec:
    workload_type: str
    run_id: str
    simulations: int
    seed: int
    confidence_level: float
    projection: Projection
    policy: Policy
    fund: Fund
    policyholder_behavior: PolicyholderBehavior
    mortality: Mortality
    expenses: Expenses

    @property
    def canonical_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))

    @property
    def input_sha256(self) -> str:
        return sha256(self.canonical_json.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class InsurancePartialResult:
    """Additive measures calculated by one Indexed Job partition."""

    workload_type: str
    run_id: str
    input_sha256: str
    partition: dict[str, int]
    simulations: int
    sum_pv_benefits: float
    sum_pv_premiums: float
    sum_pv_expenses: float
    sum_pv_net_liability: float
    sum_squared_pv_net_liability: float
    sum_maturity_account_value: float
    maturity_count: int
    guarantee_binding_count: int
    surrender_count: int
    death_claim_count: int
    elapsed_seconds: float
    engine_version: str

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def _require_integer(
    payload: dict[str, Any], key: str, *, minimum: int, maximum: int
) -> int:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise SpecError(f"{key} must be an integer between {minimum} and {maximum}")
    return value


def _object(payload: dict[str, Any], key: str) -> dict[str, Any]:
    value = payload.get(key)
    if not isinstance(value, dict):
        raise SpecError(f"{key} must be an object")
    return value


def _rate(
    payload: dict[str, Any], key: str, *, lower: float = 0.0, upper: float = 1.0
) -> float:
    value = _require_number(payload, key)
    if not lower <= value <= upper:
        raise SpecError(f"{key} must be between {lower} and {upper}")
    return value


def _run_id(payload: dict[str, Any]) -> str:
    run_id = payload.get("run_id")
    if not isinstance(run_id, str) or not run_id or len(run_id) > 64:
        raise SpecError("run_id must be a non-empty string with 64 characters or fewer")
    if not all(character.isalnum() or character in "-_" for character in run_id):
        raise SpecError("run_id may contain only letters, numbers, hyphens, and underscores")
    return run_id


def load_insurance_savings_spec(path: str | Path) -> InsuranceSavingsSpec:
    """Load a bounded, reproducible synthetic insurance-savings request."""
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SpecError(f"cannot load simulation spec: {error}") from error
    if not isinstance(payload, dict):
        raise SpecError("simulation spec must be a JSON object")
    if payload.get("workload_type") != "insurance_savings":
        raise SpecError("workload_type must be 'insurance_savings'")

    simulations = _require_integer(payload, "simulations", minimum=2, maximum=1_000_000_000)
    seed = _require_integer(payload, "seed", minimum=0, maximum=2**63 - 1)
    confidence_level = _require_number(payload, "confidence_level")
    if not 0.5 < confidence_level < 1.0:
        raise SpecError("confidence_level must be between 0.5 and 1.0")

    projection_payload = _object(payload, "projection")
    projection = Projection(
        term_years=_require_integer(projection_payload, "term_years", minimum=1, maximum=100),
        steps_per_year=_require_integer(
            projection_payload, "steps_per_year", minimum=1, maximum=365
        ),
        discount_rate=_rate(projection_payload, "discount_rate", lower=-0.1, upper=1.0),
    )
    if projection.steps_per_year != 12:
        raise SpecError(
            "projection.steps_per_year must be 12 because policy cash flows are monthly"
        )

    policy_payload = _object(payload, "policy")
    policy = Policy(
        issue_age=_require_integer(policy_payload, "issue_age", minimum=0, maximum=120),
        initial_premium=_require_number(policy_payload, "initial_premium"),
        monthly_premium=_require_number(policy_payload, "monthly_premium"),
        premium_payment_years=_require_integer(
            policy_payload, "premium_payment_years", minimum=0, maximum=projection.term_years
        ),
        maturity_guarantee=_require_number(policy_payload, "maturity_guarantee"),
        death_benefit=_require_number(policy_payload, "death_benefit"),
        surrender_charge_rate=_rate(policy_payload, "surrender_charge_rate"),
    )
    if min(
        policy.initial_premium,
        policy.monthly_premium,
        policy.maturity_guarantee,
        policy.death_benefit,
    ) < 0:
        raise SpecError("policy monetary amounts must be zero or greater")

    fund_payload = _object(payload, "fund")
    fund = Fund(
        initial_account_value=_require_number(fund_payload, "initial_account_value"),
        expected_annual_return=_rate(
            fund_payload, "expected_annual_return", lower=-1.0, upper=1.0
        ),
        annual_volatility=_rate(fund_payload, "annual_volatility"),
        annual_management_fee=_rate(fund_payload, "annual_management_fee"),
    )
    if fund.initial_account_value < 0:
        raise SpecError("fund.initial_account_value must be zero or greater")

    behavior_payload = _object(payload, "policyholder_behavior")
    behavior = PolicyholderBehavior(
        annual_lapse_rate=_rate(behavior_payload, "annual_lapse_rate"),
        lapse_rate_stress_multiplier=_rate(
            behavior_payload, "lapse_rate_stress_multiplier", lower=0.0, upper=5.0
        ),
    )
    mortality_payload = _object(payload, "mortality")
    mortality = Mortality(
        base_annual_mortality_rate=_rate(mortality_payload, "base_annual_mortality_rate"),
        annual_ageing_multiplier=_rate(
            mortality_payload, "annual_ageing_multiplier", lower=0.0, upper=5.0
        ),
    )
    expenses_payload = _object(payload, "expenses")
    expenses = Expenses(
        monthly_policy_expense=_require_number(expenses_payload, "monthly_policy_expense")
    )
    if expenses.monthly_policy_expense < 0:
        raise SpecError("expenses.monthly_policy_expense must be zero or greater")

    return InsuranceSavingsSpec(
        workload_type="insurance_savings",
        run_id=_run_id(payload),
        simulations=simulations,
        seed=seed,
        confidence_level=confidence_level,
        projection=projection,
        policy=policy,
        fund=fund,
        policyholder_behavior=behavior,
        mortality=mortality,
        expenses=expenses,
    )


def _period_probability(annual_probability: float, periods_per_year: int) -> float:
    """Convert an annual probability to the probability for one projection step."""
    return 1.0 - (1.0 - annual_probability) ** (1.0 / periods_per_year)


def run_insurance_savings_partition(
    spec: InsuranceSavingsSpec, index: int, count: int, *, engine_version: str
) -> InsurancePartialResult:
    """Simulate one deterministic partition of synthetic policy cash flows."""
    partition = partition_work(spec.simulations, index, count)
    started = perf_counter()
    size = partition.size
    if size == 0:
        return InsurancePartialResult(
            workload_type=spec.workload_type,
            run_id=spec.run_id,
            input_sha256=spec.input_sha256,
            partition=asdict(partition),
            simulations=0,
            sum_pv_benefits=0.0,
            sum_pv_premiums=0.0,
            sum_pv_expenses=0.0,
            sum_pv_net_liability=0.0,
            sum_squared_pv_net_liability=0.0,
            sum_maturity_account_value=0.0,
            maturity_count=0,
            guarantee_binding_count=0,
            surrender_count=0,
            death_claim_count=0,
            elapsed_seconds=perf_counter() - started,
            engine_version=engine_version,
        )

    periods_per_year = spec.projection.steps_per_year
    period_count = spec.projection.term_years * periods_per_year
    dt = 1.0 / periods_per_year
    premium_periods = spec.policy.premium_payment_years * periods_per_year
    discount_factors = np.exp(
        -spec.projection.discount_rate * np.arange(1, period_count + 1, dtype=np.float64) * dt
    )
    rng = np.random.default_rng(spec.seed + index * 1_000_003)
    account_value = np.full(size, spec.fund.initial_account_value, dtype=np.float64)
    active = np.ones(size, dtype=bool)
    pv_benefits = np.zeros(size, dtype=np.float64)
    pv_premiums = np.full(size, spec.policy.initial_premium, dtype=np.float64)
    pv_expenses = np.zeros(size, dtype=np.float64)
    maturity_account_values = np.zeros(size, dtype=np.float64)
    guarantee_binds = np.zeros(size, dtype=bool)
    surrenders = np.zeros(size, dtype=bool)
    death_claims = np.zeros(size, dtype=bool)

    drift = (
        spec.fund.expected_annual_return - 0.5 * spec.fund.annual_volatility**2
    ) * dt
    diffusion = spec.fund.annual_volatility * sqrt(dt)
    fee_factor = max(0.0, 1.0 - spec.fund.annual_management_fee * dt)
    annual_lapse = min(
        0.999999,
        spec.policyholder_behavior.annual_lapse_rate
        * spec.policyholder_behavior.lapse_rate_stress_multiplier,
    )
    lapse_probability = _period_probability(annual_lapse, periods_per_year)

    for period in range(1, period_count + 1):
        if not np.any(active):
            break
        discount = discount_factors[period - 1]
        if period <= premium_periods and spec.policy.monthly_premium:
            pv_premiums[active] += spec.policy.monthly_premium * discount
            account_value[active] += spec.policy.monthly_premium

        shocks = rng.standard_normal(size)
        account_value[active] *= np.exp(drift + diffusion * shocks[active]) * fee_factor
        pv_expenses[active] += spec.expenses.monthly_policy_expense * discount

        elapsed_years = period * dt
        annual_mortality = min(
            0.999999,
            spec.mortality.base_annual_mortality_rate
            * spec.mortality.annual_ageing_multiplier**elapsed_years,
        )
        death_probability = _period_probability(annual_mortality, periods_per_year)
        death_now = active & (rng.random(size) < death_probability)
        if np.any(death_now):
            pv_benefits[death_now] += (
                np.maximum(account_value[death_now], spec.policy.death_benefit) * discount
            )
            death_claims[death_now] = True
            active[death_now] = False

        lapse_now = active & (rng.random(size) < lapse_probability)
        if np.any(lapse_now):
            pv_benefits[lapse_now] += (
                account_value[lapse_now] * (1.0 - spec.policy.surrender_charge_rate) * discount
            )
            surrenders[lapse_now] = True
            active[lapse_now] = False

    maturity = active
    if np.any(maturity):
        maturity_account_values[maturity] = account_value[maturity]
        guarantee_binds[maturity] = spec.policy.maturity_guarantee > account_value[maturity]
        pv_benefits[maturity] += (
            np.maximum(account_value[maturity], spec.policy.maturity_guarantee)
            * discount_factors[-1]
        )

    pv_net_liability = pv_benefits + pv_expenses - pv_premiums
    return InsurancePartialResult(
        workload_type=spec.workload_type,
        run_id=spec.run_id,
        input_sha256=spec.input_sha256,
        partition=asdict(partition),
        simulations=size,
        sum_pv_benefits=float(pv_benefits.sum(dtype=np.float64)),
        sum_pv_premiums=float(pv_premiums.sum(dtype=np.float64)),
        sum_pv_expenses=float(pv_expenses.sum(dtype=np.float64)),
        sum_pv_net_liability=float(pv_net_liability.sum(dtype=np.float64)),
        sum_squared_pv_net_liability=float(np.square(pv_net_liability).sum(dtype=np.float64)),
        sum_maturity_account_value=float(maturity_account_values.sum(dtype=np.float64)),
        maturity_count=int(maturity.sum()),
        guarantee_binding_count=int(guarantee_binds.sum()),
        surrender_count=int(surrenders.sum()),
        death_claim_count=int(death_claims.sum()),
        elapsed_seconds=perf_counter() - started,
        engine_version=engine_version,
    )
