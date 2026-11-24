#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

GRID_FILE="${MCQS_ROOT_DIR}/examples/grids/market-risk-grid.json"
PARALLELISM=4
ARCHITECTURE="${MCQS_NODE_ARCHITECTURE:-amd64}"
QUEUE_NAME=""
VALUES_FILE=""
MAX_SCENARIOS="${MCQS_MAX_GRID_SCENARIOS:-24}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grid) GRID_FILE="${2:-}"; shift 2 ;;
    --parallelism) PARALLELISM="${2:-}"; shift 2 ;;
    --architecture) ARCHITECTURE="${2:-}"; shift 2 ;;
    --queue-name) QUEUE_NAME="${2:-}"; shift 2 ;;
    --values) VALUES_FILE="${2:-}"; shift 2 ;;
    --max-scenarios) MAX_SCENARIOS="${2:-}"; shift 2 ;;
    --help|-h)
      printf 'Usage: %s [--grid file] [--parallelism count] [--architecture amd64|arm64] [--queue-name local-queue] [--values file] [--max-scenarios count]\n' "$0"
      exit 0
      ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ -f "$GRID_FILE" ]] || mcqs_fail "Grid file not found: $GRID_FILE"
[[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "parallelism must be a positive integer."
[[ "$MAX_SCENARIOS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "max-scenarios must be a positive integer."
[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || mcqs_fail "architecture must be amd64 or arm64."
[[ -z "$VALUES_FILE" || -f "$VALUES_FILE" ]] || mcqs_fail "Helm values file not found: $VALUES_FILE"

MCQS_PYTHON="${MCQS_PYTHON:-python3}"
for binary in "$MCQS_PYTHON" jq; do
  mcqs_require_command "$binary"
done
mcqs_require_operator_environment

GRID_DIRECTORY="$(mktemp -d)"
MANIFEST_FILE="$GRID_DIRECTORY/manifest.json"
trap 'rm -rf -- "$GRID_DIRECTORY"' EXIT
"$MCQS_PYTHON" -m montecarlo.grid render \
  --grid "$GRID_FILE" \
  --output-dir "$GRID_DIRECTORY/scenarios" \
  --max-scenarios "$MAX_SCENARIOS" > "$MANIFEST_FILE"

GRID_ID="$(jq -r '.grid_id' "$MANIFEST_FILE")"
SCENARIO_COUNT="$(jq -r '.scenario_count' "$MANIFEST_FILE")"
mcqs_note "Submitting ${SCENARIO_COUNT} queued grid scenarios for ${GRID_ID}"

while IFS=$'\t' read -r scenario_id spec_file; do
  arguments=(
    --spec "$spec_file"
    --parallelism "$PARALLELISM"
    --architecture "$ARCHITECTURE"
    --grid-id "$GRID_ID"
    --scenario-id "$scenario_id"
    --no-wait
  )
  [[ -z "$QUEUE_NAME" ]] || arguments+=(--queue-name "$QUEUE_NAME")
  [[ -z "$VALUES_FILE" ]] || arguments+=(--values "$VALUES_FILE")
  "${MCQS_OPERATOR_DIR}/run-example.sh" "${arguments[@]}"
done < <(jq -r '.scenarios[] | [.scenario_id, .spec_file] | @tsv' "$MANIFEST_FILE")

printf '\nSubmitted grid %s. Monitor it with:\n  %s/grid-status.sh --grid-id %s\n' \
  "$GRID_ID" "$MCQS_OPERATOR_DIR" "$GRID_ID"
