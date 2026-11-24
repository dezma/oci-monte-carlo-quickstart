#!/usr/bin/env bash
set -euo pipefail

# Show Indexed Job progress without adding writes to the simulation hot path.
# A worker reports completion only after it has produced its immutable partial
# result, so completed partitions are an accurate durable progress measure.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

JOB_NAME=""
RUN_ID=""
PARTITIONS=""
INTERVAL_SECONDS=5
TIMEOUT="${MCQS_WAIT_TIMEOUT:-20m}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB_NAME="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --partitions) PARTITIONS="${2:-}"; shift 2 ;;
    --interval) INTERVAL_SECONDS="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --help|-h)
      printf 'Usage: %s --job <job-name> --run-id <run-id> --partitions <count> [--interval seconds] [--timeout 20m]\n\nWatches an Indexed Job and displays completed partitions, Pod phases, elapsed time, and failure status.\n' "$0"
      exit 0
      ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ -n "$JOB_NAME" ]] || mcqs_fail "job is required."
[[ -n "$RUN_ID" ]] || mcqs_fail "run-id is required."
[[ "$PARTITIONS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "partitions must be a positive integer."
[[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "interval must be a positive integer."
[[ "$TIMEOUT" =~ ^([1-9][0-9]*)(s|m|h)$ ]] || \
  mcqs_fail "timeout must be a positive duration ending in s, m, or h (for example, 20m)."
timeout_value="${BASH_REMATCH[1]}"
timeout_unit="${BASH_REMATCH[2]}"

mcqs_require_command date
mcqs_require_command jq
mcqs_require_command kubectl
mcqs_require_operator_environment
mcqs_configure_kubeconfig

case "$timeout_unit" in
  s) timeout_seconds="$timeout_value" ;;
  m) timeout_seconds=$((timeout_value * 60)) ;;
  h) timeout_seconds=$((timeout_value * 3600)) ;;
esac

format_duration() {
  local total_seconds="$1"
  printf '%02d:%02d:%02d' \
    "$((total_seconds / 3600))" \
    "$(((total_seconds % 3600) / 60))" \
    "$((total_seconds % 60))"
}

make_bar() {
  local complete="$1"
  local width=24
  local filled=$((complete * width / PARTITIONS))
  local empty=$((width - filled))
  local fill_text empty_text
  printf -v fill_text '%*s' "$filled" ''
  printf -v empty_text '%*s' "$empty" ''
  fill_text="${fill_text// /#}"
  empty_text="${empty_text// /-}"
  printf '%s%s' "$fill_text" "$empty_text"
}

display_status() {
  local message="$1"
  if [[ -t 1 ]]; then
    printf '\r\033[2K%s' "$message"
  else
    printf '%s\n' "$message"
  fi
}

started_epoch="$(date -u +%s)"
last_completed=-1
last_phase_summary=""
last_change_epoch="$started_epoch"

mcqs_note "Watching simulation Job ${JOB_NAME}"
printf 'Progress is based on completed worker partitions. A partition is counted only after its immutable result is written.\n'

while true; do
  now_epoch="$(date -u +%s)"
  elapsed_seconds=$((now_epoch - started_epoch))
  if (( elapsed_seconds >= timeout_seconds )); then
    [[ ! -t 1 ]] || printf '\n'
    mcqs_fail "Timed out after ${TIMEOUT}. Inspect the Job with: kubectl -n ${MCQS_NAMESPACE} describe job/${JOB_NAME}"
  fi

  job_json="$(kubectl -n "$MCQS_NAMESPACE" get job "$JOB_NAME" -o json)" || \
    mcqs_fail "Unable to read Job ${JOB_NAME}."
  pod_json="$(kubectl -n "$MCQS_NAMESPACE" get pods -l "monte-carlo.oracle.com/run-id=${RUN_ID}" -o json)" || \
    mcqs_fail "Unable to list Pods for run ${RUN_ID}."

  succeeded="$(jq -r '.status.succeeded // 0' <<<"$job_json")"
  failed="$(jq -r '.status.failed // 0' <<<"$job_json")"
  active="$(jq -r '.status.active // 0' <<<"$job_json")"
  complete_condition="$(jq -r 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' <<<"$job_json")"
  failed_condition="$(jq -r 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' <<<"$job_json")"
  phase_summary="$(jq -r '
    [.items[] |
      if (.status.phase // "Unknown") == "Pending" then
        ([
          .status.initContainerStatuses[]?,
          .status.containerStatuses[]?
          | select(.state.waiting? != null)
          | .state.waiting.reason
        ][0] // "Pending")
      else
        (.status.phase // "Unknown")
      end
    ]
    | group_by(.)
    | map("\(.[0])=\(length)")
    | join(" ")
    | if . == "" then "Pods=0" else . end
  ' <<<"$pod_json")"

  (( succeeded <= PARTITIONS )) || succeeded="$PARTITIONS"
  if [[ "$succeeded" != "$last_completed" || "$phase_summary" != "$last_phase_summary" ]]; then
    last_completed="$succeeded"
    last_phase_summary="$phase_summary"
    last_change_epoch="$now_epoch"
  fi
  percent=$((succeeded * 100 / PARTITIONS))
  bar="$(make_bar "$succeeded")"
  since_change="$((now_epoch - last_change_epoch))s"
  display_status "[${bar}] ${percent}%  completed=${succeeded}/${PARTITIONS} active=${active} failed=${failed} ${phase_summary} elapsed=$(format_duration "$elapsed_seconds") last-change=${since_change}"

  if [[ "$complete_condition" == "true" ]]; then
    [[ ! -t 1 ]] || printf '\n'
    printf 'Job completed: %s/%s partitions in %s.\n' \
      "$succeeded" "$PARTITIONS" "$(format_duration "$elapsed_seconds")"
    exit 0
  fi
  if [[ "$failed_condition" == "true" ]]; then
    [[ ! -t 1 ]] || printf '\n'
    printf 'Job failed after %s. Inspect logs with:\n' "$(format_duration "$elapsed_seconds")" >&2
    printf 'kubectl -n %s logs -l monte-carlo.oracle.com/run-id=%q --all-containers=true --prefix --tail=-1\n' \
      "$MCQS_NAMESPACE" "$RUN_ID" >&2
    exit 1
  fi
  sleep "$INTERVAL_SECONDS"
done
