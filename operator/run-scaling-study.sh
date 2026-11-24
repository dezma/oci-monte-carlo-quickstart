#!/usr/bin/env bash
set -euo pipefail

# Runs a controlled, background-capable scaling study for one or more
# Terraform-managed benchmark profiles. A study keeps the image digest, node
# capacity, result path, and test input consistent while measuring:
#   * strong scaling: fixed total work at increasing parallelism;
#   * weak scaling: fixed work per worker at increasing parallelism; and
#   * throughput saturation: derived from the strong-scaling curve.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

SPEC_FILE="${MCQS_ROOT_DIR}/examples/benchmarks/insurance-savings-throughput-50m.json"
PARALLELISM_LEVELS="2,4,6,8"
STRONG_SIMULATIONS=50000000
WEAK_SIMULATIONS_PER_WORKER=12500000
WARMUP_RUNS=1
MEASURED_RUNS=5
VALUES_FILE=""
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results/scaling-studies"
STUDY_ID=""
PROFILE_LIST=""
BACKGROUND=false
FOREGROUND=false

usage() {
  printf '%s\n' "Usage: $0 [--background] [--study-id id] [--profiles id,id,...] [--spec file] [--parallelism-levels 2,4,6,8] [--strong-simulations count] [--weak-simulations-per-worker count] [--warmup-runs count] [--measured-runs count] [--values file] [--output-parent dir]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --background) BACKGROUND=true; shift ;;
    --foreground) FOREGROUND=true; shift ;;
    --study-id) STUDY_ID="${2:-}"; shift 2 ;;
    --profiles) PROFILE_LIST="${2:-}"; shift 2 ;;
    --spec) SPEC_FILE="${2:-}"; shift 2 ;;
    --parallelism-levels) PARALLELISM_LEVELS="${2:-}"; shift 2 ;;
    --strong-simulations) STRONG_SIMULATIONS="${2:-}"; shift 2 ;;
    --weak-simulations-per-worker) WEAK_SIMULATIONS_PER_WORKER="${2:-}"; shift 2 ;;
    --warmup-runs) WARMUP_RUNS="${2:-}"; shift 2 ;;
    --measured-runs) MEASURED_RUNS="${2:-}"; shift 2 ;;
    --values) VALUES_FILE="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ -f "$SPEC_FILE" ]] || mcqs_fail "Scaling-study spec not found: ${SPEC_FILE}"
SPEC_FILE="$(cd -- "$(dirname -- "$SPEC_FILE")" && pwd -P)/$(basename -- "$SPEC_FILE")"
[[ "$STRONG_SIMULATIONS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "strong-simulations must be a positive integer."
[[ "$WEAK_SIMULATIONS_PER_WORKER" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "weak-simulations-per-worker must be a positive integer."
[[ "$WARMUP_RUNS" =~ ^[0-9]+$ ]] || mcqs_fail "warmup-runs must be zero or a positive integer."
[[ "$MEASURED_RUNS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "measured-runs must be a positive integer."
[[ -z "$VALUES_FILE" || -f "$VALUES_FILE" ]] || mcqs_fail "Helm values file not found: ${VALUES_FILE}"
[[ -d "$OUTPUT_PARENT" || ! -e "$OUTPUT_PARENT" ]] || mcqs_fail "output-parent exists but is not a directory: ${OUTPUT_PARENT}"

IFS=',' read -r -a PARALLELISM_VALUES <<<"$PARALLELISM_LEVELS"
(( ${#PARALLELISM_VALUES[@]} >= 2 )) || mcqs_fail "parallelism-levels must contain at least two values."
previous_parallelism=0
declare -A SEEN_PARALLELISM=()
for parallelism in "${PARALLELISM_VALUES[@]}"; do
  [[ "$parallelism" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "parallelism-levels must be comma-separated positive integers."
  (( parallelism > previous_parallelism )) || mcqs_fail "parallelism-levels must be strictly increasing."
  [[ -z "${SEEN_PARALLELISM[$parallelism]:-}" ]] || mcqs_fail "parallelism-levels cannot contain duplicate values."
  SEEN_PARALLELISM[$parallelism]=true
  previous_parallelism="$parallelism"
done

if [[ -z "$STUDY_ID" ]]; then
  STUDY_ID="insurance-scaling-$(date -u +%Y%m%d%H%M%S)"
fi
[[ "$STUDY_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#STUDY_ID} -le 63 ]] || \
  mcqs_fail "study-id must contain lowercase letters, digits, and hyphens (63 characters or fewer)."

OUTPUT_PARENT="${OUTPUT_PARENT%/}"
STUDY_DIR="${OUTPUT_PARENT}/${STUDY_ID}"
STATUS_FILE="${STUDY_DIR}/study-status.json"
STUDY_LOG="${STUDY_DIR}/study.log"
PID_FILE="${STUDY_DIR}/study.pid"
PROFILE_RECORDS='[]'
STUDY_STARTED_AT=""

write_status() {
  local state="$1"
  local current_profile="$2"
  local current_experiment="$3"
  local current_parallelism="$4"
  local message="$5"
  local completed_at="${6:-}"
  local temporary_file
  temporary_file="$(mktemp "${STUDY_DIR}/.study-status.XXXXXX")"
  jq -n \
    --arg study_id "$STUDY_ID" \
    --arg state "$state" \
    --arg current_profile "$current_profile" \
    --arg current_experiment "$current_experiment" \
    --arg current_parallelism "$current_parallelism" \
    --arg message "$message" \
    --arg spec_file "$SPEC_FILE" \
    --arg started_at "$STUDY_STARTED_AT" \
    --arg completed_at "$completed_at" \
    --arg parallelism_levels "$PARALLELISM_LEVELS" \
    --argjson strong_simulations "$STRONG_SIMULATIONS" \
    --argjson weak_simulations_per_worker "$WEAK_SIMULATIONS_PER_WORKER" \
    --argjson warmup_runs "$WARMUP_RUNS" \
    --argjson measured_runs "$MEASURED_RUNS" \
    --argjson profiles "$PROFILE_RECORDS" \
    '{study_id: $study_id, state: $state, current_profile: $current_profile, current_experiment: $current_experiment, current_parallelism: (if $current_parallelism == "" then null else ($current_parallelism | tonumber) end), message: $message, spec_file: $spec_file, started_at: $started_at, parallelism_levels: ($parallelism_levels | split(",") | map(tonumber)), strong_simulations: $strong_simulations, weak_simulations_per_worker: $weak_simulations_per_worker, warmup_runs: $warmup_runs, measured_runs: $measured_runs, profiles: $profiles} + (if $completed_at == "" then {} else {completed_at: $completed_at} end)' \
    >"$temporary_file"
  chmod 0600 "$temporary_file"
  mv -f "$temporary_file" "$STATUS_FILE"
}

set_profile_state() {
  local profile="$1"
  local state="$2"
  local message="$3"
  local strong_completed="${4:-}"
  local weak_completed="${5:-}"
  PROFILE_RECORDS="$(jq \
    --arg profile "$profile" \
    --arg state "$state" \
    --arg message "$message" \
    --argjson strong_completed "$strong_completed" \
    --argjson weak_completed "$weak_completed" \
    'map(if .id == $profile then . + {state: $state, message: $message} + (if $strong_completed == "" then {} else {strong_completed: $strong_completed} end) + (if $weak_completed == "" then {} else {weak_completed: $weak_completed} end) else . end)' \
    <<<"$PROFILE_RECORDS")"
}

if [[ "$BACKGROUND" == true ]]; then
  [[ "$FOREGROUND" == false ]] || mcqs_fail "background and foreground cannot be used together."
  [[ ! -e "$STUDY_DIR" ]] || mcqs_fail "Scaling-study output directory already exists: ${STUDY_DIR}"
  mkdir -p "$STUDY_DIR"
  chmod 0700 "$STUDY_DIR"
  STUDY_STARTED_AT="$(date -u +%FT%TZ)"
  write_status "starting" "" "" "" "Starting scaling study."

  child_arguments=(
    --foreground
    --study-id "$STUDY_ID"
    --spec "$SPEC_FILE"
    --parallelism-levels "$PARALLELISM_LEVELS"
    --strong-simulations "$STRONG_SIMULATIONS"
    --weak-simulations-per-worker "$WEAK_SIMULATIONS_PER_WORKER"
    --warmup-runs "$WARMUP_RUNS"
    --measured-runs "$MEASURED_RUNS"
    --output-parent "$OUTPUT_PARENT"
  )
  [[ -z "$PROFILE_LIST" ]] || child_arguments+=(--profiles "$PROFILE_LIST")
  [[ -z "$VALUES_FILE" ]] || child_arguments+=(--values "$VALUES_FILE")

  nohup "$MCQS_OPERATOR_DIR/run-scaling-study.sh" "${child_arguments[@]}" \
    >"$STUDY_LOG" 2>&1 < /dev/null &
  study_pid=$!
  disown "$study_pid" 2>/dev/null || true
  temporary_pid_file="$(mktemp "${STUDY_DIR}/.study.pid.XXXXXX")"
  printf '%s\n' "$study_pid" >"$temporary_pid_file"
  chmod 0600 "$temporary_pid_file"
  mv -f "$temporary_pid_file" "$PID_FILE"

  mcqs_note "Scaling study started"
  printf 'Study ID: %s\nPID:      %s\nLog:      %s\n' "$STUDY_ID" "$study_pid" "$STUDY_LOG"
  printf 'Progress: ./operator/scaling-study-status.sh --study-id %s --follow\n' "$STUDY_ID"
  exit 0
fi

[[ "$FOREGROUND" == true ]] || mcqs_fail "Use --background for a detached study, or --foreground when a process supervisor starts this command."
mcqs_require_operator_environment
for binary in date jq kubectl sha256sum; do
  mcqs_require_command "$binary"
done
mcqs_configure_kubeconfig

CONFIG_FILE="${MCQS_BENCHMARK_POOL_CONFIG:-/etc/mcqs-benchmark-pools.json}"
[[ -r "$CONFIG_FILE" ]] || mcqs_fail "A scaling study requires Terraform-managed benchmark profiles in ${CONFIG_FILE}."
[[ ! -e "$STUDY_DIR" ]] || [[ -f "$STATUS_FILE" ]] || \
  mcqs_fail "Scaling-study output directory exists without a study status: ${STUDY_DIR}"
mkdir -p "$STUDY_DIR/specs" "$STUDY_DIR/points" "$STUDY_DIR/profiles" "$STUDY_DIR/logs"
chmod 0700 "$STUDY_DIR" "$STUDY_DIR/specs" "$STUDY_DIR/points" "$STUDY_DIR/profiles" "$STUDY_DIR/logs"

if [[ -z "$PROFILE_LIST" ]]; then
  mapfile -t REQUESTED_PROFILES < <(jq -r 'keys[]' "$CONFIG_FILE")
else
  IFS=',' read -r -a REQUESTED_PROFILES <<<"$PROFILE_LIST"
fi
(( ${#REQUESTED_PROFILES[@]} > 0 )) || mcqs_fail "No benchmark profiles were selected."

for profile in "${REQUESTED_PROFILES[@]}"; do
  [[ "$profile" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "Invalid benchmark profile: ${profile}"
  jq -e --arg profile "$profile" '.[$profile] | objects' "$CONFIG_FILE" >/dev/null || \
    mcqs_fail "Benchmark profile ${profile} is not defined in ${CONFIG_FILE}."
done

STUDY_STARTED_AT="$(jq -r '.started_at // empty' "$STATUS_FILE" 2>/dev/null || true)"
[[ -n "$STUDY_STARTED_AT" ]] || STUDY_STARTED_AT="$(date -u +%FT%TZ)"

ELIGIBLE_PROFILES=()
for profile in "${REQUESTED_PROFILES[@]}"; do
  architecture="$(jq -r --arg profile "$profile" '.[$profile].architecture' "$CONFIG_FILE")"
  selector_key="$(jq -r --arg profile "$profile" '.[$profile].selector.key' "$CONFIG_FILE")"
  selector_value="$(jq -r --arg profile "$profile" '.[$profile].selector.value' "$CONFIG_FILE")"
  [[ "$architecture" == "amd64" || "$architecture" == "arm64" ]] || mcqs_fail "Benchmark profile ${profile} has an invalid architecture."

  if reconcile_output="$("${MCQS_OPERATOR_DIR}/reconcile-benchmark-pools.sh" --profile "$profile" --wait-seconds 60 2>&1)"; then
    node_inventory="$(kubectl get nodes -l "${selector_key}=${selector_value}" -o json | jq --arg architecture "$architecture" '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select(.metadata.labels["kubernetes.io/arch"] == $architecture) | {name: .metadata.name, instance_type: .metadata.labels["node.kubernetes.io/instance-type"], architecture: .metadata.labels["kubernetes.io/arch"], kubernetes_version: .status.nodeInfo.kubeletVersion, allocatable: .status.allocatable}]')"
    ready_nodes="$(jq 'length' <<<"$node_inventory")"
  else
    node_inventory='[]'
    ready_nodes=0
  fi

  profile_state="pending"
  profile_message="Ready for execution."
  if (( ready_nodes < 2 )); then
    profile_state="skipped"
    profile_message="Requires two Ready ${architecture} profile nodes. ${reconcile_output:-}"
  else
    ELIGIBLE_PROFILES+=("$profile")
  fi
  profile_record="$(jq -n \
    --arg id "$profile" \
    --arg architecture "$architecture" \
    --arg selector "${selector_key}=${selector_value}" \
    --arg state "$profile_state" \
    --arg message "$profile_message" \
    --argjson ready_nodes "$ready_nodes" \
    --argjson node_inventory "$node_inventory" \
    '{id: $id, architecture: $architecture, selector: $selector, ready_nodes: $ready_nodes, node_inventory: $node_inventory, state: $state, message: $message, strong_completed: 0, weak_completed: 0}')"
  PROFILE_RECORDS="$(jq --argjson record "$profile_record" '. + [$record]' <<<"$PROFILE_RECORDS")"
done

write_status "running" "" "" "" "Preparing selected benchmark profiles."
STUDY_TOKEN="$(printf '%s' "$STUDY_ID" | sha256sum | cut -c1-12)"
POINT_FILES=()
failures=0

run_point() {
  local profile="$1"
  local architecture="$2"
  local experiment="$3"
  local parallelism="$4"
  local simulations="$5"
  local sequence="$6"
  local point_spec="${STUDY_DIR}/specs/${profile}-${experiment}-p${parallelism}.json"
  local point_id="scaling-${STUDY_TOKEN}-${profile}-${experiment}-p${parallelism}"
  local profile_root="${STUDY_DIR}/profiles/${profile}"
  local point_dir="${profile_root}/${point_id}"
  local log_file="${STUDY_DIR}/logs/${profile}-${experiment}-p${parallelism}.log"
  local point_file="${STUDY_DIR}/points/${profile}-${experiment}-p${parallelism}.json"

  jq --arg run_id "scaling-${experiment}-p${parallelism}" --argjson simulations "$simulations" \
    '.run_id = $run_id | .simulations = $simulations' "$SPEC_FILE" >"$point_spec"
  mkdir -p "$profile_root"
  chmod 0700 "$profile_root"

  write_status "running" "$profile" "$experiment" "$parallelism" "Running ${experiment} scaling at ${parallelism} workers."
  mcqs_note "Scaling study ${STUDY_ID}: ${profile}, ${experiment}, ${parallelism} workers"
  arguments=(
    --spec "$point_spec"
    --profile-id "$profile"
    --architecture "$architecture"
    --parallelism "$parallelism"
    --warmup-runs "$WARMUP_RUNS"
    --measured-runs "$MEASURED_RUNS"
    --output-parent "$profile_root"
    --benchmark-id "$point_id"
  )
  [[ -z "$VALUES_FILE" ]] || arguments+=(--values "$VALUES_FILE")

  if ! "${MCQS_OPERATOR_DIR}/run-benchmark.sh" "${arguments[@]}" 2>&1 | tee "$log_file"; then
    return 1
  fi
  [[ -s "${point_dir}/benchmark-summary.json" ]] || return 1
  jq -n \
    --arg study_id "$STUDY_ID" \
    --arg profile_id "$profile" \
    --arg architecture "$architecture" \
    --arg experiment "$experiment" \
    --arg summary_file "${point_dir}/benchmark-summary.json" \
    --arg result_directory "$point_dir" \
    --argjson parallelism "$parallelism" \
    --argjson simulations "$simulations" \
    --slurpfile summary "${point_dir}/benchmark-summary.json" \
    '{study_id: $study_id, profile_id: $profile_id, architecture: $architecture, experiment: $experiment, parallelism: $parallelism, simulations: $simulations, summary_file: $summary_file, result_directory: $result_directory} + ($summary[0] | {benchmark_id, image: (.runs[0].image // {}), input_sha256: (.runs[0].summary.input_sha256 // null), measured_runs, median_wall_clock_seconds, p95_wall_clock_seconds, median_simulations_per_wall_second, median_simulations_per_worker_second})' \
    >"$point_file"
  POINT_FILES+=("$point_file")
  return 0
}

for profile in "${ELIGIBLE_PROFILES[@]}"; do
  architecture="$(jq -r --arg profile "$profile" '.[] | select(.id == $profile) | .architecture' <<<"$PROFILE_RECORDS")"
  strong_completed=0
  weak_completed=0
  set_profile_state "$profile" "running" "Scaling study is running." "$strong_completed" "$weak_completed"
  write_status "running" "$profile" "" "" "Running profile ${profile}."

  profile_failed=false
  for parallelism in "${PARALLELISM_VALUES[@]}"; do
    if run_point "$profile" "$architecture" "strong" "$parallelism" "$STRONG_SIMULATIONS" "$strong_completed"; then
      strong_completed=$((strong_completed + 1))
      set_profile_state "$profile" "running" "Strong-scaling points complete: ${strong_completed}/${#PARALLELISM_VALUES[@]}." "$strong_completed" "$weak_completed"
    else
      failures=1
      profile_failed=true
      set_profile_state "$profile" "failed" "Strong-scaling point at ${parallelism} workers failed. See logs/${profile}-strong-p${parallelism}.log." "$strong_completed" "$weak_completed"
      break
    fi
  done

  if [[ "$profile_failed" == false ]]; then
    for parallelism in "${PARALLELISM_VALUES[@]}"; do
      weak_simulations=$((WEAK_SIMULATIONS_PER_WORKER * parallelism))
      if run_point "$profile" "$architecture" "weak" "$parallelism" "$weak_simulations" "$weak_completed"; then
        weak_completed=$((weak_completed + 1))
        set_profile_state "$profile" "running" "Weak-scaling points complete: ${weak_completed}/${#PARALLELISM_VALUES[@]}." "$strong_completed" "$weak_completed"
      else
        failures=1
        profile_failed=true
        set_profile_state "$profile" "failed" "Weak-scaling point at ${parallelism} workers failed. See logs/${profile}-weak-p${parallelism}.log." "$strong_completed" "$weak_completed"
        break
      fi
    done
  fi

  if [[ "$profile_failed" == false ]]; then
    set_profile_state "$profile" "completed" "Strong, weak, and saturation analysis completed." "$strong_completed" "$weak_completed"
  fi
  write_status "running" "" "" "" "Completed profile ${profile}."
done

SUMMARY_JSON="${STUDY_DIR}/scaling-study-summary.json"
SUMMARY_CSV="${STUDY_DIR}/scaling-study-summary.csv"
if (( ${#POINT_FILES[@]} > 0 )); then
  jq -s \
    --arg study_id "$STUDY_ID" \
    --arg spec_file "$SPEC_FILE" \
    --arg started_at "$STUDY_STARTED_AT" \
    --arg completed_at "$(date -u +%FT%TZ)" \
    --argjson parallelism_levels "$(printf '%s\n' "${PARALLELISM_VALUES[@]}" | jq -R 'tonumber' | jq -s .)" \
    --argjson strong_simulations "$STRONG_SIMULATIONS" \
    --argjson weak_simulations_per_worker "$WEAK_SIMULATIONS_PER_WORKER" \
    --argjson warmup_runs "$WARMUP_RUNS" \
    --argjson measured_runs "$MEASURED_RUNS" \
    --argjson profiles "$PROFILE_RECORDS" \
    '
      def strong_points($all; $profile): [ $all[] | select(.profile_id == $profile and .experiment == "strong") ] | sort_by(.parallelism);
      def weak_points($all; $profile): [ $all[] | select(.profile_id == $profile and .experiment == "weak") ] | sort_by(.parallelism);
      def enriched_strong($all; $profile):
        strong_points($all; $profile) as $points |
        if ($points | length) == 0 then [] else
          $points[0] as $baseline |
          [$points[] | . + {
            speedup_vs_min_parallelism: ($baseline.median_wall_clock_seconds / .median_wall_clock_seconds),
            ideal_speedup_vs_min_parallelism: (.parallelism / $baseline.parallelism),
            parallel_efficiency: (($baseline.median_wall_clock_seconds / .median_wall_clock_seconds) / (.parallelism / $baseline.parallelism)),
            throughput_ratio_vs_min_parallelism: (.median_simulations_per_wall_second / $baseline.median_simulations_per_wall_second)
          }]
        end;
      def enriched_weak($all; $profile):
        weak_points($all; $profile) as $points |
        if ($points | length) == 0 then [] else
          $points[0] as $baseline |
          [$points[] | . + {
            wall_clock_ratio_vs_min_parallelism: (.median_wall_clock_seconds / $baseline.median_wall_clock_seconds),
            worker_throughput_ratio_vs_min_parallelism: (.median_simulations_per_worker_second / $baseline.median_simulations_per_worker_second)
          }]
        end;
      def saturation($strong):
        if ($strong | length) == 0 then null else
          ($strong | max_by(.median_simulations_per_wall_second)) as $peak |
          {
            peak_parallelism: $peak.parallelism,
            peak_simulations_per_wall_second: $peak.median_simulations_per_wall_second,
            peak_wall_clock_seconds: $peak.median_wall_clock_seconds,
            points: $strong
          }
        end;
      . as $points |
      {
        study_id: $study_id,
        spec_file: $spec_file,
        started_at: $started_at,
        completed_at: $completed_at,
        parallelism_levels: $parallelism_levels,
        strong_simulations: $strong_simulations,
        weak_simulations_per_worker: $weak_simulations_per_worker,
        warmup_runs: $warmup_runs,
        measured_runs: $measured_runs,
        profiles: [
          $profiles[] as $profile |
          (enriched_strong($points; $profile.id)) as $strong |
          (enriched_weak($points; $profile.id)) as $weak |
          $profile + {
            strong_scaling: $strong,
            weak_scaling: $weak,
            throughput_saturation: saturation($strong)
          }
        ]
      }
    ' "${POINT_FILES[@]}" >"$SUMMARY_JSON"
else
  jq -n \
    --arg study_id "$STUDY_ID" \
    --arg spec_file "$SPEC_FILE" \
    --arg started_at "$STUDY_STARTED_AT" \
    --arg completed_at "$(date -u +%FT%TZ)" \
    --argjson profiles "$PROFILE_RECORDS" \
    '{study_id: $study_id, spec_file: $spec_file, started_at: $started_at, completed_at: $completed_at, profiles: $profiles}' \
    >"$SUMMARY_JSON"
fi

jq -r '
  ["study_id", "profile_id", "architecture", "experiment", "parallelism", "simulations", "median_wall_clock_seconds", "p95_wall_clock_seconds", "median_simulations_per_wall_second", "median_simulations_per_worker_second", "speedup_vs_min_parallelism", "parallel_efficiency", "wall_clock_ratio_vs_min_parallelism", "worker_throughput_ratio_vs_min_parallelism"],
  (.profiles[] as $profile |
    ($profile.strong_scaling[]? | [
      .study_id, .profile_id, .architecture, "strong", .parallelism, .simulations,
      .median_wall_clock_seconds, .p95_wall_clock_seconds,
      .median_simulations_per_wall_second, .median_simulations_per_worker_second,
      .speedup_vs_min_parallelism, .parallel_efficiency, null, null
    ]),
    ($profile.weak_scaling[]? | [
      .study_id, .profile_id, .architecture, "weak", .parallelism, .simulations,
      .median_wall_clock_seconds, .p95_wall_clock_seconds,
      .median_simulations_per_wall_second, .median_simulations_per_worker_second,
      null, null, .wall_clock_ratio_vs_min_parallelism, .worker_throughput_ratio_vs_min_parallelism
    ])
  ) | @csv
' "$SUMMARY_JSON" >"$SUMMARY_CSV"

final_state="completed"
final_message="All eligible scaling-study profiles completed."
if (( failures > 0 )); then
  final_state="completed_with_failures"
  final_message="One or more scaling-study points failed; review the profile logs."
elif (( ${#ELIGIBLE_PROFILES[@]} == 0 )); then
  final_state="completed_with_skips"
  final_message="No selected profile had two Ready matching nodes."
fi
write_status "$final_state" "" "" "" "$final_message" "$(date -u +%FT%TZ)"

mcqs_note "Scaling study ${final_state}"
printf 'JSON summary: %s\nCSV summary:  %s\n' "$SUMMARY_JSON" "$SUMMARY_CSV"
jq '{study_id, profiles: [.profiles[] | {id, state, strong_scaling, weak_scaling, throughput_saturation}]}' "$SUMMARY_JSON"

(( failures == 0 ))
