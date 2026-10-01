"""Small CLI used by each Kubernetes Indexed Job pod."""

from __future__ import annotations

import argparse
import json
import os
import sys

from . import __version__
from .engine import run_partition
from .spec import SpecError, load_spec
from .storage import write_result


def _integer_environment(name: str) -> int:
    value = os.getenv(name)
    if value is None:
        raise ValueError(f"required environment variable {name} is not set")
    return int(value)


def _worker(arguments: argparse.Namespace) -> int:
    spec = load_spec(arguments.spec)
    index = (
        arguments.index
        if arguments.index is not None
        else _integer_environment("JOB_COMPLETION_INDEX")
    )
    workers = (
        arguments.workers
        if arguments.workers is not None
        else _integer_environment("JOB_COMPLETIONS")
    )
    partial = run_partition(spec, index, workers, engine_version=__version__)
    result = partial.to_dict()
    result["result_uri"] = write_result(result)
    print(json.dumps(result, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run a reproducible Monte Carlo job partition.")
    subcommands = parser.add_subparsers(dest="command", required=True)
    worker = subcommands.add_parser("worker", help="run one Indexed Job partition")
    worker.add_argument(
        "--spec", required=True, help="path to a validated simulation JSON document"
    )
    worker.add_argument(
        "--index", type=int, help="partition index; defaults to JOB_COMPLETION_INDEX"
    )
    worker.add_argument("--workers", type=int, help="partition count; defaults to JOB_COMPLETIONS")

    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "worker":
            return _worker(arguments)
    except (SpecError, ValueError) as error:
        print(f"input-error: {error}", file=sys.stderr)
        return 2
    except Exception as error:  # Never print environment contents from a job.
        print(f"execution-error: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 2
