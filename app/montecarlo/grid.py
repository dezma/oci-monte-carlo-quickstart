"""Expand a bounded market-risk grid into validated simulation specifications."""

from __future__ import annotations

import argparse
import copy
import itertools
import json
import re
from pathlib import Path
from typing import Any

from .spec import SpecError, load_spec

_GRID_IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
_ALLOWED_AXES = {
    "product_type",
    "barrier",
    "cash_payoff",
    "market.spot",
    "market.strike",
    "market.risk_free_rate",
    "market.volatility",
    "market.maturity_years",
    "market.dividend_yield",
}


class GridError(ValueError):
    """Raised when a grid cannot be safely expanded into simulation inputs."""


def _load_grid(path: str | Path) -> dict[str, Any]:
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GridError(f"cannot load grid: {error}") from error
    if not isinstance(payload, dict):
        raise GridError("grid must be a JSON object")
    return payload


def _set_axis_value(spec: dict[str, Any], axis: str, value: Any) -> None:
    if axis not in _ALLOWED_AXES:
        allowed = ", ".join(sorted(_ALLOWED_AXES))
        raise GridError(f"unsupported grid axis {axis!r}; allowed axes are {allowed}")
    if axis.startswith("market."):
        market = spec.get("market")
        if not isinstance(market, dict):
            raise GridError("base_spec.market must be an object")
        market[axis.removeprefix("market.")] = value
    else:
        spec[axis] = value


def render_grid(path: str | Path, output_dir: str | Path, max_scenarios: int) -> dict[str, Any]:
    """Write validated scenario specs and return a deterministic manifest."""
    if max_scenarios < 1:
        raise GridError("max_scenarios must be a positive integer")
    payload = _load_grid(path)
    grid_id = payload.get("grid_id")
    if not isinstance(grid_id, str) or not _GRID_IDENTIFIER.fullmatch(grid_id):
        raise GridError(
            "grid_id must contain lowercase letters, digits, and hyphens (48 characters maximum)"
        )
    base_spec = payload.get("base_spec")
    if not isinstance(base_spec, dict):
        raise GridError("base_spec must be a simulation-spec object")
    raw_axes = payload.get("axes")
    if not isinstance(raw_axes, dict) or not raw_axes:
        raise GridError("axes must be a non-empty object of scenario values")

    axes = sorted(raw_axes)
    axis_values: list[list[Any]] = []
    for axis in axes:
        values = raw_axes[axis]
        if not isinstance(axis, str):
            raise GridError("grid axis names must be strings")
        if axis not in _ALLOWED_AXES:
            _set_axis_value(copy.deepcopy(base_spec), axis, None)
        if not isinstance(values, list) or not values:
            raise GridError(f"grid axis {axis!r} must contain at least one value")
        axis_values.append(values)

    scenario_count = 1
    for values in axis_values:
        scenario_count *= len(values)
    if scenario_count > max_scenarios:
        raise GridError(
            f"grid expands to {scenario_count} scenarios, exceeding max_scenarios={max_scenarios}"
        )

    destination = Path(output_dir)
    destination.mkdir(parents=True, exist_ok=True)
    scenarios: list[dict[str, Any]] = []
    for index, values in enumerate(itertools.product(*axis_values), start=1):
        spec = copy.deepcopy(base_spec)
        scenario_values = dict(zip(axes, values, strict=True))
        for axis, value in scenario_values.items():
            _set_axis_value(spec, axis, value)
        scenario_id = f"s{index:03d}"
        spec["run_id"] = f"{grid_id}-{scenario_id}"
        spec_path = destination / f"{scenario_id}.json"
        spec_path.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        try:
            validated = load_spec(spec_path)
        except SpecError as error:
            raise GridError(f"scenario {scenario_id} is invalid: {error}") from error
        scenarios.append(
            {
                "scenario_id": scenario_id,
                "spec_file": str(spec_path.resolve()),
                "input_sha256": validated.input_sha256,
                "axes": scenario_values,
            }
        )
    return {"grid_id": grid_id, "scenario_count": scenario_count, "scenarios": scenarios}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Expand a bounded Monte Carlo market-risk grid.")
    subcommands = parser.add_subparsers(dest="command", required=True)
    render = subcommands.add_parser(
        "render", help="write one validated JSON simulation spec per scenario"
    )
    render.add_argument("--grid", required=True, help="path to a market-risk grid JSON file")
    render.add_argument(
        "--output-dir", required=True, help="directory for generated scenario specs"
    )
    render.add_argument("--max-scenarios", type=int, default=24)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "render":
            print(
                json.dumps(
                    render_grid(arguments.grid, arguments.output_dir, arguments.max_scenarios),
                    sort_keys=True,
                )
            )
            return 0
    except GridError as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
