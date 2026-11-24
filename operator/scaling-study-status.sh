#!/usr/bin/env bash
set -euo pipefail

# Shows durable progress and the final summary for a foreground or detached
# scaling study. It reads files only, so it is safe to use after reconnecting
# through OCI Bastion.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

STUDY_ID=""
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results/scaling-studies"
FOLLOW=false
INTERVAL=10
SHOW_LOG=false

usage() {
  printf '%s\n' "Usage: $0 --study-id id [--output-parent dir] [--follow] [--interval seconds] [--log]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --study-id) STUDY_ID="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --follow) FOLLOW=true; shift ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --log) SHOW_LOG=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$STUDY_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "study-id must contain lowercase letters, digits, and hyphens."
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "interval must be a positive integer."
mcqs_require_command jq

STUDY_DIR="${OUTPUT_PARENT%/}/${STUDY_ID}"
STATUS_FILE="${STUDY_DIR}/study-status.json"
STUDY_LOG="${STUDY_DIR}/study.log"
SUMMARY_FILE="${STUDY_DIR}/scaling-study-summary.json"
[[ -r "$STATUS_FILE" ]] || mcqs_fail "Scaling-study status was not found: ${STATUS_FILE}"

show_status() {
  jq -r '
    "Study:    \(.study_id)",
    "State:    \(.state)",
    "Started:  \(.started_at)",
    (if .completed_at then "Finished: \(.completed_at)" else empty end),
    (if .current_profile != "" then "Running:  \(.current_profile) / \(.current_experiment) / \(.current_parallelism) workers" else empty end),
    "Message:  \(.message)",
    "",
    "PROFILE\tSTATE\tREADY NODES\tSTRONG\tWEAK\tDETAIL"
  ' "$STATUS_FILE"

  render_rows() {
    jq -r --argjson point_count "$(jq '.parallelism_levels | length' "$STATUS_FILE")" '
      .profiles[] | [
        .id,
        .state,
        .ready_nodes,
        "\(.strong_completed // 0)/\($point_count)",
        "\(.weak_completed // 0)/\($point_count)",
        .message
      ] | @tsv
    ' "$STATUS_FILE"
  }

  if command -v column >/dev/null 2>&1; then
    render_rows | column -t -s $'\t'
  else
    render_rows
  fi

  if [[ -r "$SUMMARY_FILE" ]] && [[ "$(jq -r '.state' "$STATUS_FILE")" != "running" ]]; then
    printf '\nFinal throughput-saturation summary:\n'
    jq -r '
      ["PROFILE", "PEAK WORKERS", "PEAK PATHS/S", "PEAK WALL (S)"],
      (.profiles[] | [
        .id,
        (.throughput_saturation.peak_parallelism // "-"),
        (.throughput_saturation.peak_simulations_per_wall_second // "-"),
        (.throughput_saturation.peak_wall_clock_seconds // "-")
      ]) | @tsv
    ' "$SUMMARY_FILE" | { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }
  fi

  if [[ "$SHOW_LOG" == true && -r "$STUDY_LOG" ]]; then
    printf '\nRecent log entries:\n'
    tail -n 20 "$STUDY_LOG"
  fi
}

while true; do
  if [[ "$FOLLOW" == true ]]; then
    printf '\033[H\033[2J'
  fi
  show_status
  state="$(jq -r '.state' "$STATUS_FILE")"
  if [[ "$FOLLOW" == false || ( "$state" != "running" && "$state" != "starting" ) ]]; then
    break
  fi
  sleep "$INTERVAL"
done
