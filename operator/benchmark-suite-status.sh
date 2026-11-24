#!/usr/bin/env bash
set -euo pipefail

# Shows durable progress for a foreground or background benchmark suite.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

SUITE_ID=""
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results/suites"
FOLLOW=false
INTERVAL=10
SHOW_LOG=false

usage() {
  printf '%s\n' "Usage: $0 --suite-id id [--output-parent dir] [--follow] [--interval seconds] [--log]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite-id) SUITE_ID="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --follow) FOLLOW=true; shift ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --log) SHOW_LOG=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$SUITE_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  mcqs_fail "suite-id must contain lowercase letters, digits, and hyphens."
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "interval must be a positive integer."
mcqs_require_command jq

SUITE_DIR="${OUTPUT_PARENT%/}/${SUITE_ID}"
STATUS_FILE="${SUITE_DIR}/suite-status.json"
SUITE_LOG="${SUITE_DIR}/suite.log"
[[ -r "$STATUS_FILE" ]] || mcqs_fail "Suite status was not found: ${STATUS_FILE}"

show_status() {
  local status_file="$1"
  local warmup_runs measured_runs
  warmup_runs="$(jq -r '.warmup_runs' "$status_file")"
  measured_runs="$(jq -r '.measured_runs' "$status_file")"

  jq -r '
    "Suite:    \(.suite_id)",
    "State:    \(.state)",
    (if .strict_ocpu then "Mode:     strict OCI-OCPU" else "Mode:     application policy" end),
    "Started:  \(.started_at)",
    (if .completed_at then "Finished: \(.completed_at)" else empty end),
    (if .current_profile != "" then "Running:  \(.current_profile)" else empty end),
    "Message:  \(.message)",
    "",
    "PROFILE\tSTATE\tREADY NODES\tWARM-UP\tMEASURED\tDETAIL"
  ' "$status_file"

  if [[ -r "${SUITE_DIR}/suite.pid" ]]; then
    suite_pid="$(<"${SUITE_DIR}/suite.pid")"
    if [[ "$suite_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$suite_pid" 2>/dev/null; then
      printf 'Runner:   PID %s (running)\n\n' "$suite_pid"
    else
      printf 'Runner:   recorded PID %s is not running\n\n' "$suite_pid"
    fi
  fi

  render_profile_rows() {
    while IFS=$'\t' read -r profile state ready_nodes result_dir message; do
      warmup_completed=0
      measured_completed=0
      if [[ -d "$result_dir" ]]; then
        # A run writes both its internal reducer summary (for example,
        # warmup-01.summary.json) and its completed benchmark record
        # (warmup-01.json). Count only completed records, otherwise the
        # progress display reports each finished run twice.
        mapfile -t warmup_records < <(find "$result_dir" -maxdepth 1 -type f -name 'warmup-[0-9][0-9].json' -print)
        mapfile -t measured_records < <(find "$result_dir" -maxdepth 1 -type f -name 'measured-[0-9][0-9].json' -print)
        warmup_completed="${#warmup_records[@]}"
        measured_completed="${#measured_records[@]}"
      fi
      printf '%s\t%s\t%s\t%s/%s\t%s/%s\t%s\n' \
        "$profile" "$state" "$ready_nodes" \
        "$warmup_completed" "$warmup_runs" \
        "$measured_completed" "$measured_runs" "$message"
    done < <(jq -r '.profiles[] | [.id, .state, .ready_nodes, .result_dir, .message] | @tsv' "$status_file")
  }

  if command -v column >/dev/null 2>&1; then
    render_profile_rows | column -t -s $'\t'
  else
    render_profile_rows
  fi

  if [[ "$SHOW_LOG" == true && -r "$SUITE_LOG" ]]; then
    printf '\nRecent log entries:\n'
    tail -n 20 "$SUITE_LOG"
  fi
}

while true; do
  if [[ "$FOLLOW" == true ]]; then
    printf '\033[H\033[2J'
  fi
  show_status "$STATUS_FILE"
  state="$(jq -r '.state' "$STATUS_FILE")"
  if [[ "$FOLLOW" == false || "$state" != "running" && "$state" != "starting" ]]; then
    break
  fi
  sleep "$INTERVAL"
done
