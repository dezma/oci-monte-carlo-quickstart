#!/usr/bin/env bash
set -euo pipefail

# Stops a detached scaling study and removes only its active Job. Completed
# point reports remain available in the study directory for analysis.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

STUDY_ID=""
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results/scaling-studies"

usage() {
  printf '%s\n' "Usage: $0 --study-id id [--output-parent dir]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --study-id) STUDY_ID="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$STUDY_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "study-id must contain lowercase letters, digits, and hyphens."
mcqs_require_operator_environment
for binary in jq kubectl sha256sum date pgrep; do
  mcqs_require_command "$binary"
done
mcqs_configure_kubeconfig

STUDY_DIR="${OUTPUT_PARENT%/}/${STUDY_ID}"
STATUS_FILE="${STUDY_DIR}/study-status.json"
PID_FILE="${STUDY_DIR}/study.pid"
[[ -r "$STATUS_FILE" ]] || mcqs_fail "Scaling-study status was not found: ${STATUS_FILE}"

state="$(jq -r '.state' "$STATUS_FILE")"
current_profile="$(jq -r '.current_profile' "$STATUS_FILE")"
current_experiment="$(jq -r '.current_experiment' "$STATUS_FILE")"
current_parallelism="$(jq -r '.current_parallelism // empty' "$STATUS_FILE")"
if [[ "$state" != "running" && "$state" != "starting" ]]; then
  mcqs_fail "Scaling study ${STUDY_ID} is already ${state}; no active study was stopped."
fi

# Stop the controller before deleting its active Job, preventing it from
# advancing to the next point. Its direct children are the benchmark runner
# and log writer; Job deletion releases any remaining Kubernetes wait.
if [[ -r "$PID_FILE" ]]; then
  study_pid="$(<"$PID_FILE")"
  if [[ "$study_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$study_pid" 2>/dev/null; then
    child_pids="$(pgrep -P "$study_pid" || true)"
    [[ -z "$child_pids" ]] || kill $child_pids 2>/dev/null || true
    kill "$study_pid" 2>/dev/null || true
    printf 'Stopped scaling-study runner PID %s.\n' "$study_pid"
  fi
fi

if [[ -n "$current_profile" && -n "$current_experiment" && -n "$current_parallelism" ]]; then
  study_token="$(printf '%s' "$STUDY_ID" | sha256sum | cut -c1-12)"
  benchmark_id="scaling-${study_token}-${current_profile}-${current_experiment}-p${current_parallelism}"
  kubectl -n "$MCQS_NAMESPACE" delete job \
    -l "monte-carlo.oracle.com/benchmark-id=${benchmark_id}" \
    --ignore-not-found >/dev/null
  printf 'Removed active Job for %s at %s workers.\n' "$current_profile" "$current_parallelism"
fi

temporary_status="$(mktemp "${STUDY_DIR}/.study-status.XXXXXX")"
jq --arg completed_at "$(date -u +%FT%TZ)" \
  '.state = "cancelled" | .current_profile = "" | .current_experiment = "" | .current_parallelism = null | .message = "Stopped by the operator." | .completed_at = $completed_at' \
  "$STATUS_FILE" >"$temporary_status"
chmod 0600 "$temporary_status"
mv -f "$temporary_status" "$STATUS_FILE"

printf 'Scaling study %s is cancelled. Completed point reports remain in %s.\n' "$STUDY_ID" "$STUDY_DIR"
