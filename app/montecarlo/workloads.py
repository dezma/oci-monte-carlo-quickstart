"""Dispatch validated workload inputs without conflating their result contracts."""

from __future__ import annotations

import json
from pathlib import Path

from .insurance import InsuranceSavingsSpec, load_insurance_savings_spec
from .spec import SimulationSpec, SpecError, load_spec

WorkloadSpec = SimulationSpec | InsuranceSavingsSpec


def load_workload_spec(path: str | Path) -> WorkloadSpec:
    """Load an option-pricing input or a named first-class workload input."""
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SpecError(f"cannot load simulation spec: {error}") from error
    if not isinstance(payload, dict):
        raise SpecError("simulation spec must be a JSON object")

    workload_type = payload.get("workload_type")
    if workload_type in (None, "option_pricing"):
        return load_spec(path)
    if workload_type == "insurance_savings":
        return load_insurance_savings_spec(path)
    raise SpecError("workload_type must be 'option_pricing' or 'insurance_savings'")
