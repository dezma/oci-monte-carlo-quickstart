#!/usr/bin/env bash
set -euo pipefail

# Runs selected Terraform-managed benchmark profiles one at a time. A suite
# keeps the same workload, image, and test settings for every profile, while
# avoiding cross-profile resource contention that would weaken the comparison.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

SPEC_FILE="${MCQS_ROOT_DIR}/examples/benchmarks/insurance-savings-throughput-50m.json"
PARALLELISM=4
WARMUP_RUNS=1
MEASURED_RUNS=5
VALUES_FILE=""
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results/suites"
SUITE_ID=""
PROFILE_LIST=""
BACKGROUND=false
FOREGROUND=false
STRICT_OCPU=false

usage() {
  printf '%s\n' "Usage: $0 [--background] [--strict-ocpu] [--suite-id id] [--profiles id,id,...] [--spec file] [--parallelism count] [--warmup-runs count] [--measured-runs count] [--values file] [--output-parent dir]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --background) BACKGROUND=true; shift ;;
    --foreground) FOREGROUND=true; shift ;;
    --strict-ocpu) STRICT_OCPU=true; shift ;;
    --suite-id) SUITE_ID="${2:-}"; shift 2 ;;
    --profiles) PROFILE_LIST="${2:-}"; shift 2 ;;
    --spec) SPEC_FILE="${2:-}"; shift 2 ;;
    --parallelism) PARALLELISM="${2:-}"; shift 2 ;;
    --warmup-runs) WARMUP_RUNS="${2:-}"; shift 2 ;;
    --measured-runs) MEASURED_RUNS="${2:-}"; shift 2 ;;
    --values) VALUES_FILE="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

if [[ "$STRICT_OCPU" == true ]] && [[ "$SPEC_FILE" == "${MCQS_ROOT_DIR}/examples/benchmarks/insurance-savings-throughput-50m.json" ]]; then
  SPEC_FILE="${MCQS_ROOT_DIR}/examples/benchmarks/insurance-savings-throughput-100m.json"
fi

[[ -f "$SPEC_FILE" ]] || mcqs_fail "Benchmark spec not found: ${SPEC_FILE}"
SPEC_FILE="$(cd -- "$(dirname -- "$SPEC_FILE")" && pwd -P)/$(basename -- "$SPEC_FILE")"
[[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "parallelism must be a positive integer."
[[ "$WARMUP_RUNS" =~ ^[0-9]+$ ]] || mcqs_fail "warmup-runs must be zero or a positive integer."
[[ "$MEASURED_RUNS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "measured-runs must be a positive integer."
[[ -z "$VALUES_FILE" || -f "$VALUES_FILE" ]] || mcqs_fail "Helm values file not found: ${VALUES_FILE}"

if [[ -z "$SUITE_ID" ]]; then
  SUITE_ID="insurance-suite-$(date -u +%Y%m%d%H%M%S)"
fi
[[ "$SUITE_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#SUITE_ID} -le 63 ]] || \
  mcqs_fail "suite-id must contain lowercase letters, digits, and hyphens (63 characters or fewer)."

OUTPUT_PARENT="${OUTPUT_PARENT%/}"
SUITE_DIR="${OUTPUT_PARENT}/${SUITE_ID}"
STATUS_FILE="${SUITE_DIR}/suite-status.json"
SUITE_LOG="${SUITE_DIR}/suite.log"
SUITE_PID_FILE="${SUITE_DIR}/suite.pid"

write_starting_status() {
  local temporary_file
  temporary_file="$(mktemp "${SUITE_DIR}/.suite-status.XXXXXX")"
  jq -n \
    --arg suite_id "$SUITE_ID" \
    --arg spec_file "$SPEC_FILE" \
    --arg started_at "$(date -u +%FT%TZ)" \
    --argjson parallelism "$PARALLELISM" \
    --argjson warmup_runs "$WARMUP_RUNS" \
    --argjson measured_runs "$MEASURED_RUNS" \
    --argjson strict_ocpu "$STRICT_OCPU" \
    '{suite_id: $suite_id, state: "starting", spec_file: $spec_file, started_at: $started_at, parallelism: $parallelism, warmup_runs: $warmup_runs, measured_runs: $measured_runs, strict_ocpu: $strict_ocpu, profiles: []}' \
    > "$temporary_file"
  chmod 0600 "$temporary_file"
  mv -f "$temporary_file" "$STATUS_FILE"
}

if [[ "$BACKGROUND" == true ]]; then
  [[ "$FOREGROUND" == false ]] || mcqs_fail "background and foreground cannot be used together."
  [[ ! -e "$SUITE_DIR" ]] || mcqs_fail "Suite output directory already exists: ${SUITE_DIR}"
  mkdir -p "$SUITE_DIR"
  chmod 0700 "$SUITE_DIR"
  write_starting_status

  child_arguments=(
    --foreground
    --suite-id "$SUITE_ID"
    --spec "$SPEC_FILE"
    --parallelism "$PARALLELISM"
    --warmup-runs "$WARMUP_RUNS"
    --measured-runs "$MEASURED_RUNS"
    --output-parent "$OUTPUT_PARENT"
  )
  [[ -z "$PROFILE_LIST" ]] || child_arguments+=(--profiles "$PROFILE_LIST")
  [[ -z "$VALUES_FILE" ]] || child_arguments+=(--values "$VALUES_FILE")
  [[ "$STRICT_OCPU" == true ]] && child_arguments+=(--strict-ocpu)

  nohup "$MCQS_OPERATOR_DIR/run-benchmark-suite.sh" "${child_arguments[@]}" \
    > "$SUITE_LOG" 2>&1 < /dev/null &
  suite_pid=$!
  disown "$suite_pid" 2>/dev/null || true
  temporary_pid_file="$(mktemp "${SUITE_DIR}/.suite.pid.XXXXXX")"
  printf '%s\n' "$suite_pid" > "$temporary_pid_file"
  chmod 0600 "$temporary_pid_file"
  mv -f "$temporary_pid_file" "$SUITE_PID_FILE"

  mcqs_note "Benchmark suite started"
  printf 'Suite ID: %s\nPID:      %s\nLog:      %s\n' "$SUITE_ID" "$suite_pid" "$SUITE_LOG"
  printf 'Progress: ./operator/benchmark-suite-status.sh --suite-id %s --follow\n' "$SUITE_ID"
  exit 0
fi

[[ "$FOREGROUND" == true ]] || mcqs_fail "Use --background for a detached suite, or --foreground when a process supervisor starts this command."
mcqs_require_operator_environment
for binary in date jq kubectl; do
  mcqs_require_command "$binary"
done
mcqs_configure_kubeconfig

CONFIG_FILE="${MCQS_BENCHMARK_POOL_CONFIG:-/etc/mcqs-benchmark-pools.json}"
[[ -r "$CONFIG_FILE" ]] || mcqs_fail "A benchmark suite requires Terraform-managed benchmark profiles in ${CONFIG_FILE}. Select benchmark profiles during provisioning and refresh the operator configuration."
[[ ! -e "$SUITE_DIR" ]] || [[ -f "$STATUS_FILE" ]] || \
  mcqs_fail "Suite output directory exists without suite status: ${SUITE_DIR}"
mkdir -p "$SUITE_DIR" "$SUITE_DIR/profiles" "$SUITE_DIR/summaries"
chmod 0700 "$SUITE_DIR" "$SUITE_DIR/profiles" "$SUITE_DIR/summaries"

if [[ -z "$PROFILE_LIST" ]]; then
  mapfile -t REQUESTED_PROFILES < <(jq -r 'keys[]' "$CONFIG_FILE")
else
  IFS=',' read -r -a REQUESTED_PROFILES <<< "$PROFILE_LIST"
fi
(( ${#REQUESTED_PROFILES[@]} > 0 )) || mcqs_fail "No benchmark profiles were selected."

for profile in "${REQUESTED_PROFILES[@]}"; do
  [[ "$profile" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
    mcqs_fail "Invalid benchmark profile: ${profile}"
  jq -e --arg profile "$profile" '.[$profile] | objects' "$CONFIG_FILE" >/dev/null || \
    mcqs_fail "Benchmark profile ${profile} is not defined in ${CONFIG_FILE}."
done

PROFILE_RECORDS='[]'
ELIGIBLE_PROFILES=()
for profile in "${REQUESTED_PROFILES[@]}"; do
  architecture="$(jq -r --arg profile "$profile" '.[$profile].architecture' "$CONFIG_FILE")"
  selector_key="$(jq -r --arg profile "$profile" '.[$profile].selector.key' "$CONFIG_FILE")"
  selector_value="$(jq -r --arg profile "$profile" '.[$profile].selector.value' "$CONFIG_FILE")"
  [[ "$architecture" == "amd64" || "$architecture" == "arm64" ]] || \
    mcqs_fail "Benchmark profile ${profile} has an invalid architecture."
  [[ "$selector_key" != "null" && "$selector_value" != "null" ]] || \
    mcqs_fail "Benchmark profile ${profile} has an incomplete node selector."

  profile_benchmark_id="suite-$(printf '%s' "${SUITE_ID}:${profile}" | sha256sum | cut -c1-12)-${profile}"
  profile_result_dir="${SUITE_DIR}/profiles/${profile_benchmark_id}"
  profile_state="pending"
  profile_message="Ready for execution."

  # Reapply the desired taint before each suite so replacement or scale-out
  # nodes stay isolated to their selected profile.
  if ! reconcile_output="$("${MCQS_OPERATOR_DIR}/reconcile-benchmark-pools.sh" --profile "$profile" --wait-seconds 30 2>&1)"; then
    ready_nodes=0
    profile_state="skipped"
    profile_message="Profile nodes are not ready: $(tail -n 1 <<<"$reconcile_output")"
  else
    ready_nodes="$(kubectl get nodes -l "${selector_key}=${selector_value}" -o json | jq --arg architecture "$architecture" '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select(.metadata.labels["kubernetes.io/arch"] == $architecture)] | length')"
  fi
  if [[ "$profile_state" != "skipped" ]] && (( ready_nodes < 2 )); then
    profile_state="skipped"
    profile_message="Requires two Ready ${architecture} nodes matching ${selector_key}=${selector_value}; found ${ready_nodes}."
  else
    if [[ "$profile_state" != "skipped" ]]; then
      ELIGIBLE_PROFILES+=("$profile")
    fi
  fi
  profile_record="$(jq -n \
    --arg id "$profile" \
    --arg architecture "$architecture" \
    --arg selector "${selector_key}=${selector_value}" \
    --arg state "$profile_state" \
    --arg message "$profile_message" \
    --arg result_dir "$profile_result_dir" \
    --arg benchmark_id "$profile_benchmark_id" \
    --argjson ready_nodes "$ready_nodes" \
    '{id: $id, architecture: $architecture, selector: $selector, ready_nodes: $ready_nodes, state: $state, message: $message, result_dir: $result_dir, benchmark_id: $benchmark_id}')"
  PROFILE_RECORDS="$(jq --argjson record "$profile_record" '. + [$record]' <<< "$PROFILE_RECORDS")"
done

write_status() {
  local state="$1"
  local current_profile="$2"
  local message="$3"
  local completed_at="${4:-}"
  local temporary_file
  temporary_file="$(mktemp "${SUITE_DIR}/.suite-status.XXXXXX")"
  jq -n \
    --arg suite_id "$SUITE_ID" \
    --arg state "$state" \
    --arg current_profile "$current_profile" \
    --arg message "$message" \
    --arg spec_file "$SPEC_FILE" \
    --arg started_at "${SUITE_STARTED_AT}" \
    --arg completed_at "$completed_at" \
    --argjson parallelism "$PARALLELISM" \
    --argjson warmup_runs "$WARMUP_RUNS" \
    --argjson measured_runs "$MEASURED_RUNS" \
    --argjson strict_ocpu "$STRICT_OCPU" \
    --argjson profiles "$PROFILE_RECORDS" \
    '{suite_id: $suite_id, state: $state, current_profile: $current_profile, message: $message, spec_file: $spec_file, started_at: $started_at, parallelism: $parallelism, warmup_runs: $warmup_runs, measured_runs: $measured_runs, strict_ocpu: $strict_ocpu, profiles: $profiles} + (if $completed_at == "" then {} else {completed_at: $completed_at} end)' \
    > "$temporary_file"
  chmod 0600 "$temporary_file"
  mv -f "$temporary_file" "$STATUS_FILE"
}

set_profile_state() {
  local profile="$1"
  local state="$2"
  local message="$3"
  local summary_file="${4:-}"
  PROFILE_RECORDS="$(jq \
    --arg profile "$profile" \
    --arg state "$state" \
    --arg message "$message" \
    --arg summary_file "$summary_file" \
    'map(if .id == $profile then . + {state: $state, message: $message} + (if $summary_file == "" then {} else {summary_file: $summary_file} end) else . end)' \
    <<< "$PROFILE_RECORDS")"
}

SUITE_STARTED_AT="$(date -u +%FT%TZ)"
write_status "running" "" "Preparing selected benchmark profiles."

failures=0
for profile in "${ELIGIBLE_PROFILES[@]}"; do
  architecture="$(jq -r --arg profile "$profile" '.[] | select(.id == $profile) | .architecture' <<< "$PROFILE_RECORDS")"
  benchmark_id="$(jq -r --arg profile "$profile" '.[] | select(.id == $profile) | .benchmark_id' <<< "$PROFILE_RECORDS")"
  result_dir="$(jq -r --arg profile "$profile" '.[] | select(.id == $profile) | .result_dir' <<< "$PROFILE_RECORDS")"
  profile_log="${SUITE_DIR}/${profile}.log"
  set_profile_state "$profile" "running" "Benchmark is running."
  write_status "running" "$profile" "Running profile ${profile}."

  mcqs_note "Suite ${SUITE_ID}: running ${profile}"
  arguments=(
    --spec "$SPEC_FILE"
    --profile-id "$profile"
    --parallelism "$PARALLELISM"
    --warmup-runs "$WARMUP_RUNS"
    --measured-runs "$MEASURED_RUNS"
    --output-parent "${SUITE_DIR}/profiles"
    --benchmark-id "$benchmark_id"
  )
  if [[ "$STRICT_OCPU" == true ]]; then
    [[ -z "$VALUES_FILE" ]] || mcqs_fail "--values is not supported with --strict-ocpu; the strict resource contract is fixed."
    runner="$MCQS_OPERATOR_DIR/run-strict-ocpu-benchmark.sh"
  else
    arguments+=(--architecture "$architecture")
    [[ -z "$VALUES_FILE" ]] || arguments+=(--values "$VALUES_FILE")
    runner="$MCQS_OPERATOR_DIR/run-benchmark.sh"
  fi

  if "$runner" "${arguments[@]}" 2>&1 | tee "$profile_log"; then
    summary_file="${result_dir}/benchmark-summary.json"
    if [[ -s "$summary_file" ]]; then
      install -m 0600 "$summary_file" "${SUITE_DIR}/summaries/${profile}.json"
      set_profile_state "$profile" "completed" "Benchmark completed." "${SUITE_DIR}/summaries/${profile}.json"
    else
      failures=1
      set_profile_state "$profile" "failed" "Benchmark completed without a summary file. See ${profile_log}."
    fi
  else
    failures=1
    set_profile_state "$profile" "failed" "Benchmark failed. See ${profile_log}."
  fi
  write_status "running" "" "Completed profile ${profile}."
done

mapfile -t SUMMARY_FILES < <(find "${SUITE_DIR}/summaries" -maxdepth 1 -type f -name '*.json' -print | sort)
if (( ${#SUMMARY_FILES[@]} > 0 )); then
  jq -s \
    --arg suite_id "$SUITE_ID" \
    --arg spec_file "$SPEC_FILE" \
    --arg started_at "$SUITE_STARTED_AT" \
    --arg completed_at "$(date -u +%FT%TZ)" \
    --argjson parallelism "$PARALLELISM" \
    --argjson warmup_runs "$WARMUP_RUNS" \
    --argjson measured_runs "$MEASURED_RUNS" \
    --argjson strict_ocpu "$STRICT_OCPU" \
    --argjson profiles "$PROFILE_RECORDS" \
    '{suite_id: $suite_id, spec_file: $spec_file, started_at: $started_at, completed_at: $completed_at, parallelism: $parallelism, warmup_runs: $warmup_runs, measured_runs: $measured_runs, strict_ocpu: $strict_ocpu, profiles: $profiles, results: map({profile_id, architecture, measured_runs, median_wall_clock_seconds, p95_wall_clock_seconds, median_simulations_per_wall_second, median_simulations_per_worker_second})}' \
    "${SUMMARY_FILES[@]}" > "${SUITE_DIR}/suite-summary.json"
  jq -r '
    ["profile_id", "architecture", "measured_runs", "median_wall_clock_seconds", "p95_wall_clock_seconds", "median_simulations_per_wall_second", "median_simulations_per_worker_second"],
    (.results[] | [.profile_id, .architecture, .measured_runs, .median_wall_clock_seconds, .p95_wall_clock_seconds, .median_simulations_per_wall_second, .median_simulations_per_worker_second]) | @csv' \
    "${SUITE_DIR}/suite-summary.json" > "${SUITE_DIR}/suite-summary.csv"
else
  jq -n \
    --arg suite_id "$SUITE_ID" \
    --arg spec_file "$SPEC_FILE" \
    --arg started_at "$SUITE_STARTED_AT" \
    --arg completed_at "$(date -u +%FT%TZ)" \
    --argjson strict_ocpu "$STRICT_OCPU" \
    --argjson profiles "$PROFILE_RECORDS" \
    '{suite_id: $suite_id, spec_file: $spec_file, started_at: $started_at, completed_at: $completed_at, strict_ocpu: $strict_ocpu, profiles: $profiles, results: []}' \
    > "${SUITE_DIR}/suite-summary.json"
  printf '%s\n' '"profile_id","architecture","measured_runs","median_wall_clock_seconds","p95_wall_clock_seconds","median_simulations_per_wall_second","median_simulations_per_worker_second"' > "${SUITE_DIR}/suite-summary.csv"
fi

final_state="completed"
final_message="All eligible profiles completed."
if (( failures > 0 )); then
  final_state="completed_with_failures"
  final_message="One or more profiles failed; see the profile logs."
elif (( ${#ELIGIBLE_PROFILES[@]} == 0 )); then
  final_state="completed_with_skips"
  final_message="No selected profile had two Ready matching nodes."
fi
SUITE_COMPLETED_AT="$(date -u +%FT%TZ)"
write_status "$final_state" "" "$final_message" "$SUITE_COMPLETED_AT"

mcqs_note "Benchmark suite ${final_state}"
printf 'JSON summary: %s\nCSV summary:  %s\n' \
  "${SUITE_DIR}/suite-summary.json" "${SUITE_DIR}/suite-summary.csv"
jq '{suite_id, results}' "${SUITE_DIR}/suite-summary.json"

(( failures == 0 ))
