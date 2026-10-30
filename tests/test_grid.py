import json
from pathlib import Path

import pytest
from montecarlo.grid import GridError, render_grid

GRID_PATH = Path(__file__).parents[1] / "examples" / "grids" / "market-risk-grid.json"
INSURANCE_GRID_PATH = (
    Path(__file__).parents[1] / "examples" / "grids" / "insurance-savings-stress-grid.json"
)


def test_grid_expands_bounded_market_risk_scenarios(tmp_path: Path) -> None:
    manifest = render_grid(GRID_PATH, tmp_path, max_scenarios=24)

    assert manifest["grid_id"] == "market-risk-demo"
    assert manifest["scenario_count"] == 9
    first = manifest["scenarios"][0]
    first_payload = json.loads(Path(first["spec_file"]).read_text(encoding="utf-8"))
    assert first["scenario_id"] == "s001"
    assert first_payload["run_id"] == "market-risk-demo-s001"
    assert first_payload["market"]["spot"] == 90.0
    assert first_payload["market"]["volatility"] == 0.15


def test_grid_refuses_unbounded_expansion(tmp_path: Path) -> None:
    with pytest.raises(GridError, match="exceeding max_scenarios"):
        render_grid(GRID_PATH, tmp_path, max_scenarios=8)


def test_grid_expands_bounded_insurance_savings_scenarios(tmp_path: Path) -> None:
    manifest = render_grid(INSURANCE_GRID_PATH, tmp_path, max_scenarios=24)

    assert manifest["grid_id"] == "insurance-savings-stress"
    assert manifest["scenario_count"] == 9
    first_payload = json.loads(Path(manifest["scenarios"][0]["spec_file"]).read_text(encoding="utf-8"))
    assert first_payload["workload_type"] == "insurance_savings"
    assert first_payload["fund"]["annual_volatility"] == 0.15
    assert first_payload["policyholder_behavior"]["lapse_rate_stress_multiplier"] == 0.75
