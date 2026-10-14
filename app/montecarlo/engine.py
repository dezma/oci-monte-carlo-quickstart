"""Deterministic, vectorized Monte Carlo calculation primitives."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from math import exp, sqrt
from time import perf_counter

import numpy as np

from .spec import SimulationSpec


@dataclass(frozen=True)
class Partition:
    index: int
    count: int
    start: int
    size: int


@dataclass(frozen=True)
class PartialResult:
    run_id: str
    input_sha256: str
    partition: dict[str, int]
    simulations: int
    sum_discounted_payoff: float
    sum_squared_discounted_payoff: float
    elapsed_seconds: float
    engine_version: str

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def partition_work(total: int, index: int, count: int) -> Partition:
    """Return a non-overlapping, nearly even partition for an Indexed Job pod."""
    if count < 1:
        raise ValueError("partition count must be at least 1")
    if not 0 <= index < count:
        raise ValueError("partition index must be between 0 and count - 1")
    base, remainder = divmod(total, count)
    size = base + (1 if index < remainder else 0)
    start = index * base + min(index, remainder)
    return Partition(index=index, count=count, start=start, size=size)


def _payoff(
    spec: SimulationSpec,
    terminal: np.ndarray,
    arithmetic_average: np.ndarray | None,
    path_minimum: np.ndarray,
    path_maximum: np.ndarray,
) -> np.ndarray:
    """Calculate the product payoff from simulated path observations."""
    market = spec.market
    underlying = arithmetic_average if spec.product_type == "asian_arithmetic" else terminal
    if underlying is None:
        raise ValueError("arithmetic averages are required for Asian products")
    vanilla = (
        np.maximum(underlying - market.strike, 0.0)
        if spec.option_type == "call"
        else np.maximum(market.strike - underlying, 0.0)
    )
    if spec.product_type == "cash_digital":
        in_the_money = (
            terminal > market.strike if spec.option_type == "call" else terminal < market.strike
        )
        return spec.cash_payoff * in_the_money.astype(np.float64)
    if spec.product_type == "up_and_out":
        if spec.barrier is None:
            raise ValueError("up_and_out product requires a barrier")
        return vanilla * (path_maximum < spec.barrier)
    if spec.product_type == "down_and_out":
        if spec.barrier is None:
            raise ValueError("down_and_out product requires a barrier")
        return vanilla * (path_minimum > spec.barrier)
    return vanilla


def _discounted_payoff_moments(
    spec: SimulationSpec, simulations: int, rng: np.random.Generator
) -> tuple[float, float]:
    """Return additive discounted-payoff moments in bounded antithetic chunks."""
    if simulations == 0:
        return 0.0, 0.0

    market = spec.market
    dt = market.maturity_years / spec.steps
    drift = (market.risk_free_rate - market.dividend_yield - 0.5 * market.volatility**2) * dt
    diffusion = market.volatility * sqrt(dt)
    discount = exp(-market.risk_free_rate * market.maturity_years)
    chunk_size = min(simulations, 100_000)
    payoff_sum = 0.0
    squared_payoff_sum = 0.0

    remaining = simulations
    while remaining:
        batch_size = min(remaining, chunk_size)
        antithetic_size = (batch_size + 1) // 2
        prices = np.full(antithetic_size, market.spot, dtype=np.float64)
        inverse_prices = np.full(antithetic_size, market.spot, dtype=np.float64)
        arithmetic_sum = np.zeros(antithetic_size, dtype=np.float64)
        inverse_arithmetic_sum = np.zeros(antithetic_size, dtype=np.float64)
        path_minimum = prices.copy()
        inverse_path_minimum = inverse_prices.copy()
        path_maximum = prices.copy()
        inverse_path_maximum = inverse_prices.copy()
        for _ in range(spec.steps):
            shock = rng.standard_normal(antithetic_size)
            prices *= np.exp(drift + diffusion * shock)
            inverse_prices *= np.exp(drift - diffusion * shock)
            arithmetic_sum += prices
            inverse_arithmetic_sum += inverse_prices
            path_minimum = np.minimum(path_minimum, prices)
            inverse_path_minimum = np.minimum(inverse_path_minimum, inverse_prices)
            path_maximum = np.maximum(path_maximum, prices)
            inverse_path_maximum = np.maximum(inverse_path_maximum, inverse_prices)
        terminal = np.concatenate((prices, inverse_prices))[:batch_size]
        arithmetic_average = np.concatenate(
            (arithmetic_sum / spec.steps, inverse_arithmetic_sum / spec.steps)
        )[:batch_size]
        minimum = np.concatenate((path_minimum, inverse_path_minimum))[:batch_size]
        maximum = np.concatenate((path_maximum, inverse_path_maximum))[:batch_size]
        discounted_payoff = (
            _payoff(spec, terminal, arithmetic_average, minimum, maximum) * discount
        )
        payoff_sum += float(discounted_payoff.sum(dtype=np.float64))
        squared_payoff_sum += float(
            np.square(discounted_payoff, dtype=np.float64).sum(dtype=np.float64)
        )
        remaining -= batch_size
    return payoff_sum, squared_payoff_sum


def run_partition(
    spec: SimulationSpec, index: int, count: int, *, engine_version: str
) -> PartialResult:
    """Run one reproducible partition and return additive aggregate statistics."""
    partition = partition_work(spec.simulations, index, count)
    started = perf_counter()
    # A large stride avoids overlapping deterministic streams between job indexes.
    rng = np.random.default_rng(spec.seed + index * 1_000_003)
    payoff_sum, squared_payoff_sum = _discounted_payoff_moments(spec, partition.size, rng)
    return PartialResult(
        run_id=spec.run_id,
        input_sha256=spec.input_sha256,
        partition={
            "index": partition.index,
            "count": partition.count,
            "start": partition.start,
            "size": partition.size,
        },
        simulations=partition.size,
        sum_discounted_payoff=payoff_sum,
        sum_squared_discounted_payoff=squared_payoff_sum,
        elapsed_seconds=perf_counter() - started,
        engine_version=engine_version,
    )
