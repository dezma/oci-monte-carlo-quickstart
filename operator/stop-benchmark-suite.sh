#!/usr/bin/env bash
set -euo pipefail

# Stops a detached benchmark suite and removes only Jobs created for its
# currently active profile. Completed profile reports remain available.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

SUITE_ID=""
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results/suites"

usage() {
  printf '%s\n' "Usage: $0 --suite-id id [--output-parent dir]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-id) SUITE_ID="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$SUITE_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  mcqs_fail "suite-id must contain lowercase letters, digits, and hyphens."

mcqs_require_operator_environment
for binary in jq kubectl date; do
  mcqs_require_command "$binary"
done
mcqs_configure_kubeconfig

SUITE_DIR="${OUTPUT_PARENT%/}/${SUITE_ID}"
STATUS_FILE="${SUITE_DIR}/suite-status.json"
PID_FILE="${SUITE_DIR}/suite.pid"
[[ -r "$STATUS_FILE" ]] || mcqs_fail "Suite status was not found: ${STATUS_FILE}"

state="$(jq -r '.state' "$STATUS_FILE")"
current_profile="$(jq -r '.current_profile' "$STATUS_FILE")"
if [[ "$state" != "running" && "$state" != "starting" ]]; then
  mcqs_fail "Suite ${SUITE_ID} is already ${state}; no active suite was stopped."
fi

# Stop the suite parent first so it cannot advance to the next profile after
# the active Job is removed. The Job deletion then releases pending/running
# Pods without affecting completed benchmark reports.
if [[ -r "$PID_FILE" ]]; then
  suite_pid="$(<"$PID_FILE")"
  if [[ "$suite_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$suite_pid" 2>/dev/null; then
    kill "$suite_pid"
    printf 'Stopped suite runner PID %s.\n' "$suite_pid"
  fi
fi

if [[ -n "$current_profile" ]]; then
  benchmark_id="$(jq -r --arg profile "$current_profile" '.profiles[] | select(.id == $profile) | .benchmark_id' "$STATUS_FILE")"
  if [[ -n "$benchmark_id" && "$benchmark_id" != "null" ]]; then
    kubectl -n "$MCQS_NAMESPACE" delete job \
      -l "monte-carlo.oracle.com/benchmark-id=${benchmark_id}" \
      --ignore-not-found >/dev/null
    printf 'Removed active Jobs for profile %s.\n' "$current_profile"
  fi
fi

temporary_status="$(mktemp "${SUITE_DIR}/.suite-status.XXXXXX")"
jq --arg completed_at "$(date -u +%FT%TZ)" \
  '.state = "cancelled" | .current_profile = "" | .message = "Stopped by the operator." | .completed_at = $completed_at' \
  "$STATUS_FILE" > "$temporary_status"
chmod 0600 "$temporary_status"
mv -f "$temporary_status" "$STATUS_FILE"

printf 'Suite %s is cancelled. Completed profile reports remain in %s.\n' "$SUITE_ID" "$SUITE_DIR"
