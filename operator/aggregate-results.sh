#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

RUN_ID=""
CONFIDENCE="0.95"
EXPECTED_PARTITIONS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    --confidence)
      CONFIDENCE="${2:-}"
      shift 2
      ;;
    --expected-partitions)
      EXPECTED_PARTITIONS="${2:-}"
      shift 2
      ;;
    --help|-h)
      printf 'Usage: %s --run-id <id> [--confidence 0.95] [--expected-partitions count]\n\nAggregates immutable Object Storage partials from one completed Monte Carlo run.\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

[[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || \
  mcqs_fail "--run-id must contain only letters, numbers, hyphens, and underscores (64 characters or fewer)."
if [[ -n "$EXPECTED_PARTITIONS" ]]; then
  [[ "$EXPECTED_PARTITIONS" =~ ^[1-9][0-9]*$ ]] || \
    mcqs_fail "--expected-partitions must be a positive integer."
fi

mcqs_require_operator_environment
MCQS_PYTHON="${MCQS_PYTHON:-python3}"
mcqs_require_command "$MCQS_PYTHON"

MCQS_OBJECT_STORAGE_BUCKET="${MCQS_OBJECT_STORAGE_BUCKET:-}"
MCQS_OBJECT_STORAGE_NAMESPACE="${MCQS_OBJECT_STORAGE_NAMESPACE:-}"
MCQS_OBJECT_STORAGE_PREFIX="${MCQS_OBJECT_STORAGE_PREFIX:-monte-carlo}"
export OCI_REGION="${OCI_REGION:-${REGION:-${MCQS_REGION:-}}}"
mcqs_require_value MCQS_OBJECT_STORAGE_BUCKET
mcqs_require_value MCQS_OBJECT_STORAGE_NAMESPACE
mcqs_require_value OCI_REGION

arguments=(
  --bucket "$MCQS_OBJECT_STORAGE_BUCKET"
  --namespace "$MCQS_OBJECT_STORAGE_NAMESPACE"
  --prefix "${MCQS_OBJECT_STORAGE_PREFIX}/runs/${RUN_ID}/partials/"
  --confidence "$CONFIDENCE"
)
if [[ -n "$EXPECTED_PARTITIONS" ]]; then
  arguments+=(--expected-partitions "$EXPECTED_PARTITIONS")
fi

PYTHONPATH="${MCQS_ROOT_DIR}/app" "$MCQS_PYTHON" -m montecarlo.aggregate "${arguments[@]}"
