from pathlib import Path

from montecarlo.engine import partition_work, run_partition
from montecarlo.spec import load_spec

SPEC_PATH = Path(__file__).parents[1] / "examples" / "sample-simulation.json"


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
