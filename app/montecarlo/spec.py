"""Input validation for a reproducible European-option simulation."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from hashlib import sha256
from pathlib import Path
from typing import Any


class SpecError(ValueError):
    """Raised when a submitted simulation specification is unsafe or invalid."""


@dataclass(frozen=True)
class Market:
    spot: float
    strike: float
    risk_free_rate: float
    volatility: float
    maturity_years: float
    dividend_yield: float = 0.0


@dataclass(frozen=True)
class SimulationSpec:
    run_id: str
    option_type: str
    simulations: int
    steps: int
    seed: int
    confidence_level: float
    market: Market
    product_type: str = "european"
    barrier: float | None = None
    cash_payoff: float = 1.0

    @property
    def canonical_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))

    @property
    def input_sha256(self) -> str:
        return sha256(self.canonical_json.encode("utf-8")).hexdigest()


def _require_number(payload: dict[str, Any], key: str, *, positive: bool = False) -> float:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise SpecError(f"{key} must be a number")
    result = float(value)
    if positive and result <= 0:
        raise SpecError(f"{key} must be greater than zero")
    return result


def load_spec(path: str | Path) -> SimulationSpec:
    """Load a bounded, deterministic simulation request from JSON."""
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SpecError(f"cannot load simulation spec: {error}") from error

    if not isinstance(payload, dict):
        raise SpecError("simulation spec must be a JSON object")

    run_id = payload.get("run_id")
    if not isinstance(run_id, str) or not run_id or len(run_id) > 64:
        raise SpecError("run_id must be a non-empty string with 64 characters or fewer")
    if not all(character.isalnum() or character in "-_" for character in run_id):
        raise SpecError("run_id may contain only letters, numbers, hyphens, and underscores")

    option_type = payload.get("option_type")
    if option_type not in {"call", "put"}:
        raise SpecError("option_type must be 'call' or 'put'")

    product_type = payload.get("product_type", "european")
    allowed_products = {
        "european",
        "cash_digital",
        "asian_arithmetic",
        "up_and_out",
        "down_and_out",
    }
    if product_type not in allowed_products:
        choices = ", ".join(sorted(allowed_products))
        raise SpecError(f"product_type must be one of {choices}")

    barrier_value = payload.get("barrier")
    barrier: float | None = None
    if product_type in {"up_and_out", "down_and_out"}:
        if barrier_value is None:
            raise SpecError(f"barrier is required for product_type {product_type}")
        barrier = _require_number({"barrier": barrier_value}, "barrier", positive=True)
    elif barrier_value is not None:
        raise SpecError("barrier is only valid for up_and_out or down_and_out products")

    cash_payoff = _require_number(
        {"cash_payoff": payload.get("cash_payoff", 1.0)}, "cash_payoff", positive=True
    )
    if product_type != "cash_digital" and "cash_payoff" in payload:
        raise SpecError("cash_payoff is only valid for cash_digital products")

    simulations = payload.get("simulations")
    if (
        isinstance(simulations, bool)
        or not isinstance(simulations, int)
        or not 1 <= simulations <= 1_000_000_000
    ):
        raise SpecError("simulations must be an integer between 1 and 1,000,000,000")

    steps = payload.get("steps", 1)
    if isinstance(steps, bool) or not isinstance(steps, int) or not 1 <= steps <= 10_000:
        raise SpecError("steps must be an integer between 1 and 10,000")

    seed = payload.get("seed")
    if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed < 2**63:
        raise SpecError("seed must be an integer between 0 and 2^63-1")

    confidence_level = _require_number(payload, "confidence_level")
    if not 0.5 < confidence_level < 1.0:
        raise SpecError("confidence_level must be between 0.5 and 1.0")

    market_payload = payload.get("market")
    if not isinstance(market_payload, dict):
        raise SpecError("market must be an object")
    market = Market(
        spot=_require_number(market_payload, "spot", positive=True),
        strike=_require_number(market_payload, "strike", positive=True),
        risk_free_rate=_require_number(market_payload, "risk_free_rate"),
        volatility=_require_number(market_payload, "volatility", positive=True),
        maturity_years=_require_number(market_payload, "maturity_years", positive=True),
        dividend_yield=_require_number(market_payload, "dividend_yield"),
    )
    return SimulationSpec(
        run_id=run_id,
        option_type=option_type,
        simulations=simulations,
        steps=steps,
        seed=seed,
        confidence_level=confidence_level,
        market=market,
        product_type=product_type,
        barrier=barrier,
        cash_payoff=cash_payoff,
    )
