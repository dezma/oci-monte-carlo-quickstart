import json
from pathlib import Path

from montecarlo.engine import partition_work, run_partition
from montecarlo.spec import load_spec

SPEC_PATH = Path(__file__).parents[1] / "examples" / "sample-simulation.json"
EXAMPLES_DIR = SPEC_PATH.parent


def test_partitions_cover_work_without_overlap() -> None:
    partitions = [partition_work(10, index, 3) for index in range(3)]
    assert [partition.size for partition in partitions] == [4, 3, 3]
    assert [partition.start for partition in partitions] == [0, 4, 7]
    assert sum(partition.size for partition in partitions) == 10


def test_partition_is_deterministic() -> None:
    spec = load_spec(SPEC_PATH)
    first = run_partition(spec, 0, 4, engine_version="test")
    second = run_partition(spec, 0, 4, engine_version="test")
    assert first.simulations == second.simulations
    assert first.sum_discounted_payoff == second.sum_discounted_payoff
    assert first.sum_squared_discounted_payoff == second.sum_squared_discounted_payoff


def test_additional_derivative_examples_produce_nonnegative_payoffs() -> None:
    for filename in ("european-put.json", "asian-call.json", "cash-digital-call.json"):
        partial = run_partition(load_spec(EXAMPLES_DIR / filename), 0, 1, engine_version="test")
        assert partial.sum_discounted_payoff >= 0.0
        assert partial.sum_squared_discounted_payoff >= 0.0


def test_up_and_out_barrier_at_spot_knocks_out_every_path(tmp_path: Path) -> None:
    payload = json.loads((EXAMPLES_DIR / "up-and-out-call.json").read_text(encoding="utf-8"))
    payload["barrier"] = payload["market"]["spot"]
    spec_path = tmp_path / "knocked-out.json"
    spec_path.write_text(json.dumps(payload), encoding="utf-8")

    partial = run_partition(load_spec(spec_path), 0, 1, engine_version="test")

    assert partial.sum_discounted_payoff == 0.0
    assert partial.sum_squared_discounted_payoff == 0.0
