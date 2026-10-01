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


def _discounted_payoffs(
    spec: SimulationSpec, simulations: int, rng: np.random.Generator
) -> np.ndarray:
    """Calculate discounted payoffs in bounded chunks using antithetic paths."""
    if simulations == 0:
        return np.empty(0, dtype=np.float64)

    market = spec.market
    dt = market.maturity_years / spec.steps
    drift = (market.risk_free_rate - market.dividend_yield - 0.5 * market.volatility**2) * dt
    diffusion = market.volatility * sqrt(dt)
    discount = exp(-market.risk_free_rate * market.maturity_years)
    chunk_size = min(simulations, 100_000)
    batches: list[np.ndarray] = []

    remaining = simulations
    while remaining:
        batch_size = min(remaining, chunk_size)
        antithetic_size = (batch_size + 1) // 2
        prices = np.full(antithetic_size, market.spot, dtype=np.float64)
        inverse_prices = np.full(antithetic_size, market.spot, dtype=np.float64)
        for _ in range(spec.steps):
            shock = rng.standard_normal(antithetic_size)
            prices *= np.exp(drift + diffusion * shock)
            inverse_prices *= np.exp(drift - diffusion * shock)
        terminal = np.concatenate((prices, inverse_prices))[:batch_size]
        if spec.option_type == "call":
            payoff = np.maximum(terminal - market.strike, 0.0)
        else:
            payoff = np.maximum(market.strike - terminal, 0.0)
        batches.append(payoff * discount)
        remaining -= batch_size
    return np.concatenate(batches)


def run_partition(
    spec: SimulationSpec, index: int, count: int, *, engine_version: str
) -> PartialResult:
    """Run one reproducible partition and return additive aggregate statistics."""
    partition = partition_work(spec.simulations, index, count)
    started = perf_counter()
    # A large stride avoids overlapping deterministic streams between job indexes.
    rng = np.random.default_rng(spec.seed + index * 1_000_003)
    payoffs = _discounted_payoffs(spec, partition.size, rng)
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
        sum_discounted_payoff=float(payoffs.sum(dtype=np.float64)),
        sum_squared_discounted_payoff=float(
            np.square(payoffs, dtype=np.float64).sum(dtype=np.float64)
        ),
        elapsed_seconds=perf_counter() - started,
        engine_version=engine_version,
    )
