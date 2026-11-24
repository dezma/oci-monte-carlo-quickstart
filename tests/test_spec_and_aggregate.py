from pathlib import Path

import pytest
from montecarlo.aggregate import aggregate, fetch_filesystem_partials, main
from montecarlo.spec import SpecError, load_spec

SPEC_PATH = Path(__file__).parents[1] / "examples" / "sample-simulation.json"


def _partial(run_id: str, input_sha256: str, payoff: float) -> dict[str, object]:
    return {
        "run_id": run_id,
        "input_sha256": input_sha256,
        "simulations": 2,
        "sum_discounted_payoff": payoff,
        "sum_squared_discounted_payoff": payoff**2 / 2,
        "elapsed_seconds": 0.1,
    }


def _partitioned_partial(
    run_id: str, input_sha256: str, payoff: float, index: int
) -> dict[str, object]:
    partial = _partial(run_id, input_sha256, payoff)
    partial["partition"] = {
        "index": index,
        "count": 2,
        "start": index * 2,
        "size": 2,
    }
    return partial


def test_aggregate_combines_additive_moments() -> None:
    spec = load_spec(SPEC_PATH)
    summary = aggregate(
        [
            _partial(spec.run_id, spec.input_sha256, 8.0),
            _partial(spec.run_id, spec.input_sha256, 12.0),
        ],
        0.95,
    )
    assert summary["simulations"] == 4
    assert summary["price"] == 5.0
    assert summary["partitions"] == 2


def test_aggregate_validates_complete_expected_partition_set() -> None:
    spec = load_spec(SPEC_PATH)
    summary = aggregate(
        [
            _partitioned_partial(spec.run_id, spec.input_sha256, 12.0, 1),
            _partitioned_partial(spec.run_id, spec.input_sha256, 8.0, 0),
        ],
        0.95,
        expected_partitions=2,
    )
    assert summary["partitions"] == 2


def test_aggregate_rejects_missing_or_duplicate_expected_partitions() -> None:
    spec = load_spec(SPEC_PATH)
    first = _partitioned_partial(spec.run_id, spec.input_sha256, 8.0, 0)
    with pytest.raises(ValueError, match="missing partial results"):
        aggregate([first], 0.95, expected_partitions=2)
    with pytest.raises(ValueError, match="duplicate partial result"):
        aggregate([first, first.copy()], 0.95, expected_partitions=2)


def test_aggregate_rejects_invalid_expected_partition_layout() -> None:
    spec = load_spec(SPEC_PATH)
    first = _partitioned_partial(spec.run_id, spec.input_sha256, 8.0, 0)
    second = _partitioned_partial(spec.run_id, spec.input_sha256, 12.0, 1)
    second["partition"] = {"index": 1, "count": 2, "start": 1, "size": 2}
    with pytest.raises(ValueError, match="non-overlapping partition layout"):
        aggregate([first, second], 0.95, expected_partitions=2)


def test_aggregate_cli_rejects_nonpositive_expected_partitions() -> None:
    with pytest.raises(SystemExit) as error:
        main(
            [
                "--bucket",
                "results",
                "--namespace",
                "namespace",
                "--prefix",
                "prefix/",
                "--expected-partitions",
                "0",
            ]
        )
    assert error.value.code == 2


def test_aggregate_rejects_mixed_runs() -> None:
    spec = load_spec(SPEC_PATH)
    with pytest.raises(ValueError, match="one reproducible run"):
        aggregate(
            [
                _partial("first", spec.input_sha256, 8.0),
                _partial("second", spec.input_sha256, 12.0),
            ],
            0.95,
        )


def test_spec_rejects_unsafe_run_identifier(tmp_path: Path) -> None:
    invalid_spec = tmp_path / "invalid.json"
    invalid_spec.write_text('{"run_id":"../bad"}', encoding="utf-8")
    with pytest.raises(SpecError, match="run_id may contain"):
        load_spec(invalid_spec)


def test_fetch_filesystem_partials_reads_only_one_run(tmp_path: Path) -> None:
    partial_directory = tmp_path / "runs" / "test-run" / "partials"
    partial_directory.mkdir(parents=True)
    (partial_directory / "part-00001.json").write_text('{"partition":1}', encoding="utf-8")
    (partial_directory / "part-00000.json").write_text('{"partition":0}', encoding="utf-8")
    other = tmp_path / "runs" / "other-run" / "partials"
    other.mkdir(parents=True)
    (other / "part-00000.json").write_text('{"partition":99}', encoding="utf-8")

    assert fetch_filesystem_partials(str(tmp_path), "test-run") == [
        {"partition": 0},
        {"partition": 1},
    ]


def test_aggregate_cli_requires_run_id_for_fss(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="--run-id is required"):
        main(["--results-dir", str(tmp_path)])
