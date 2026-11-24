#!/usr/bin/env bash
set -euo pipefail

# Runs the synthetic insurance-savings workload repeatedly and writes a local
# comparison report. Each simulation partition remains an immutable Object
# Storage result, as in a normal quickstart run.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

SPEC_FILE="${MCQS_ROOT_DIR}/examples/benchmarks/insurance-savings-throughput-50m.json"
PROFILE_ID="current-pool"
PARALLELISM=4
ARCHITECTURE="${MCQS_NODE_ARCHITECTURE:-amd64}"
WARMUP_RUNS=1
MEASURED_RUNS=5
VALUES_FILE=""
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results"
BENCHMARK_ID=""
NODE_SELECTORS=()
TOLERATIONS=()
TOPOLOGY_SPREAD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC_FILE="${2:-}"; shift 2 ;;
    --profile-id) PROFILE_ID="${2:-}"; shift 2 ;;
    --parallelism) PARALLELISM="${2:-}"; shift 2 ;;
    --architecture) ARCHITECTURE="${2:-}"; shift 2 ;;
    --warmup-runs) WARMUP_RUNS="${2:-}"; shift 2 ;;
    --measured-runs) MEASURED_RUNS="${2:-}"; shift 2 ;;
    --node-selector) NODE_SELECTORS+=("${2:-}"); shift 2 ;;
    --no-topology-spread) TOPOLOGY_SPREAD=false; shift ;;
    --values) VALUES_FILE="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --benchmark-id) BENCHMARK_ID="${2:-}"; shift 2 ;;
    --help|-h)
      printf 'Usage: %s [--spec file] [--profile-id id] [--parallelism count] [--architecture amd64|arm64] [--warmup-runs count] [--measured-runs count] [--node-selector key=value] [--no-topology-spread] [--values file] [--output-parent dir] [--benchmark-id id]\n' "$0"
      exit 0
      ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ -f "$SPEC_FILE" ]] || mcqs_fail "Benchmark spec not found: $SPEC_FILE"
[[ "$PROFILE_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  mcqs_fail "profile-id must contain lowercase letters, digits, and hyphens."
[[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "parallelism must be a positive integer."
[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || \
  mcqs_fail "architecture must be amd64 or arm64."
[[ "$WARMUP_RUNS" =~ ^[0-9]+$ ]] || mcqs_fail "warmup-runs must be zero or a positive integer."
[[ "$MEASURED_RUNS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "measured-runs must be a positive integer."
[[ -z "$VALUES_FILE" || -f "$VALUES_FILE" ]] || mcqs_fail "Helm values file not found: $VALUES_FILE"
[[ -d "$OUTPUT_PARENT" || ! -e "$OUTPUT_PARENT" ]] || \
  mcqs_fail "output-parent exists but is not a directory: $OUTPUT_PARENT"

if [[ -z "$BENCHMARK_ID" ]]; then
  BENCHMARK_ID="insurance-${PROFILE_ID}-$(date -u +%Y%m%d%H%M%S)"
fi
[[ "$BENCHMARK_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#BENCHMARK_ID} -le 63 ]] || \
  mcqs_fail "benchmark-id must contain lowercase letters, digits, and hyphens (63 characters or fewer)."

for selector in "${NODE_SELECTORS[@]}"; do
  selector_key="${selector%%=*}"
  selector_value="${selector#*=}"
  [[ "$selector" == *=* && -n "$selector_key" && -n "$selector_value" ]] || \
    mcqs_fail "node-selector must use key=value syntax."
done

mcqs_require_operator_environment
for binary in date jq kubectl helm sha256sum; do
  mcqs_require_command "$binary"
done

# Topology spreading is rendered by run-example.sh and the Helm chart. Refuse
# a mixed revision explicitly: otherwise an older runner reports an unhelpful
# unknown-option error after the benchmark has already created its result dir.
if [[ "$TOPOLOGY_SPREAD" == true ]] && ! grep -q -- '--topology-spread' "${MCQS_OPERATOR_DIR}/run-example.sh"; then
  mcqs_fail "Benchmark node spreading requires matching operator/run-benchmark.sh and operator/run-example.sh revisions. Update the complete operator/ and helm/monte-carlo/ directories, then rerun."
fi

# If Terraform created a dedicated benchmark profile, make the safe placement
# path automatic: verify the requested architecture, repair current node
# taints, and target the profile label. Existing clusters without the optional
# Terraform map keep the original explicit --node-selector workflow.
BENCHMARK_POOL_CONFIG="${MCQS_BENCHMARK_POOL_CONFIG:-/etc/mcqs-benchmark-pools.json}"
if [[ -r "$BENCHMARK_POOL_CONFIG" ]] && jq -e --arg profile "$PROFILE_ID" '.[$profile] | objects' "$BENCHMARK_POOL_CONFIG" >/dev/null; then
  CONFIGURED_ARCHITECTURE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].architecture' "$BENCHMARK_POOL_CONFIG")"
  PROFILE_SELECTOR_KEY="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].selector.key' "$BENCHMARK_POOL_CONFIG")"
  PROFILE_SELECTOR_VALUE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].selector.value' "$BENCHMARK_POOL_CONFIG")"
  PROFILE_TAINT_KEY="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.key' "$BENCHMARK_POOL_CONFIG")"
  PROFILE_TAINT_VALUE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.value' "$BENCHMARK_POOL_CONFIG")"
  PROFILE_TAINT_EFFECT="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.effect' "$BENCHMARK_POOL_CONFIG")"
  [[ "$CONFIGURED_ARCHITECTURE" == "$ARCHITECTURE" ]] || \
    mcqs_fail "profile ${PROFILE_ID} uses ${CONFIGURED_ARCHITECTURE}; rerun with --architecture ${CONFIGURED_ARCHITECTURE}."
  [[ "$PROFILE_SELECTOR_KEY" != "null" && "$PROFILE_SELECTOR_VALUE" != "null" && "$PROFILE_TAINT_KEY" != "null" && "$PROFILE_TAINT_VALUE" != "null" && "$PROFILE_TAINT_EFFECT" == "NoSchedule" ]] || \
    mcqs_fail "profile ${PROFILE_ID} has an incomplete Terraform benchmark-pool configuration."

  for selector in "${NODE_SELECTORS[@]}"; do
    [[ "$selector" != "${PROFILE_SELECTOR_KEY}="* || "$selector" == "${PROFILE_SELECTOR_KEY}=${PROFILE_SELECTOR_VALUE}" ]] || \
      mcqs_fail "profile ${PROFILE_ID} conflicts with --node-selector ${selector}."
  done
  if [[ ! " ${NODE_SELECTORS[*]} " == *" ${PROFILE_SELECTOR_KEY}=${PROFILE_SELECTOR_VALUE} "* ]]; then
    NODE_SELECTORS+=("${PROFILE_SELECTOR_KEY}=${PROFILE_SELECTOR_VALUE}")
  fi
  TOLERATIONS+=("${PROFILE_TAINT_KEY}=${PROFILE_TAINT_VALUE}:${PROFILE_TAINT_EFFECT}")

  "${MCQS_OPERATOR_DIR}/reconcile-benchmark-pools.sh" --profile "$PROFILE_ID"
fi

# run-example appends a timestamp and limits run IDs to 40 characters. Do not
# derive a prefix by truncating the human-readable benchmark ID: doing so can
# discard minute/second precision and collide with an immutable ConfigMap or
# Job from an earlier run. A short digest keeps each series distinct while the
# benchmark labels retain the readable identifier for reporting and queries.
BENCHMARK_RUN_TOKEN="$(printf '%s' "$BENCHMARK_ID" | sha256sum | cut -c1-12)"

RESULTS_DIR="${OUTPUT_PARENT%/}/${BENCHMARK_ID}"
[[ ! -e "$RESULTS_DIR" ]] || mcqs_fail "Benchmark output directory already exists: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
chmod 0700 "$RESULTS_DIR"

mcqs_load_image_metadata
mcqs_require_value MCQS_IMAGE_REPOSITORY
mcqs_require_value MCQS_IMAGE_DIGEST

# FSS is checked on two selected hosts before the warm-up. This keeps CSI
# mount or private-image initialization outside measured execution and returns
# a focused diagnostic instead of leaving a benchmark Job at its long runtime
# deadline.
if [[ "${MCQS_RESULT_DELIVERY_MODE:-fss}" == "fss" ]]; then
  fss_probe_arguments=(--architecture "$ARCHITECTURE")
  for selector in "${NODE_SELECTORS[@]}"; do
    fss_probe_arguments+=(--node-selector "$selector")
  done
  for toleration in "${TOLERATIONS[@]}"; do
    fss_probe_arguments+=(--toleration "$toleration")
  done
  "${MCQS_OPERATOR_DIR}/fss-mount-probe.sh" "${fss_probe_arguments[@]}"
fi

write_record() {
  local phase="$1"
  local sequence="$2"
  local summary_file="$3"
  local started_at="$4"
  local completed_at="$5"
  local wall_seconds="$6"
  local record_file="$RESULTS_DIR/${phase}-$(printf '%02d' "$sequence").json"

  jq -n \
    --arg benchmark_id "$BENCHMARK_ID" \
    --arg profile_id "$PROFILE_ID" \
    --arg phase "$phase" \
    --arg architecture "$ARCHITECTURE" \
    --arg image_repository "$MCQS_IMAGE_REPOSITORY" \
    --arg image_digest "$MCQS_IMAGE_DIGEST" \
    --arg started_at "$started_at" \
    --arg completed_at "$completed_at" \
    --argjson sequence "$sequence" \
    --argjson parallelism "$PARALLELISM" \
    --argjson wall_clock_seconds "$wall_seconds" \
    --slurpfile summary "$summary_file" \
    '{
      benchmark_id: $benchmark_id,
      profile_id: $profile_id,
      phase: $phase,
      sequence: $sequence,
      architecture: $architecture,
      image: {repository: $image_repository, digest: $image_digest},
      started_at: $started_at,
      completed_at: $completed_at,
      parallelism: $parallelism,
      wall_clock_seconds: $wall_clock_seconds,
      summary: $summary[0]
    } + (if $wall_clock_seconds > 0 then {
      simulations_per_wall_second: ($summary[0].simulations / $wall_clock_seconds),
      simulations_per_worker_second: ($summary[0].simulations / $summary[0].total_worker_seconds)
    } else {} end)' > "$record_file"
}

run_one() {
  local phase="$1"
  local sequence="$2"
  local summary_file="$RESULTS_DIR/${phase}-$(printf '%02d' "$sequence").summary.json"
  local log_file="$RESULTS_DIR/${phase}-$(printf '%02d' "$sequence").log"
  local run_prefix
  run_prefix="benchmark-${BENCHMARK_RUN_TOKEN}-${phase:0:1}${sequence}"
  local started_epoch completed_epoch wall_seconds
  started_epoch="$(date -u +%s)"
  local arguments=(
    --spec "$SPEC_FILE"
    --parallelism "$PARALLELISM"
    --architecture "$ARCHITECTURE"
    --run-id-prefix "$run_prefix"
    --benchmark-id "$BENCHMARK_ID"
    --benchmark-profile "$PROFILE_ID"
    --benchmark-phase "$phase"
    --summary-file "$summary_file"
  )
  if [[ "$TOPOLOGY_SPREAD" == true ]]; then
    arguments+=(--topology-spread)
  fi
  for selector in "${NODE_SELECTORS[@]}"; do
    arguments+=(--node-selector "$selector")
  done
  for toleration in "${TOLERATIONS[@]}"; do
    arguments+=(--toleration "$toleration")
  done
  [[ -z "$VALUES_FILE" ]] || arguments+=(--values "$VALUES_FILE")

  mcqs_note "Benchmark ${BENCHMARK_ID}: ${phase} run ${sequence}"
  if ! "${MCQS_OPERATOR_DIR}/run-example.sh" "${arguments[@]}" 2>&1 | tee "$log_file"; then
    mcqs_fail "Benchmark ${phase} run ${sequence} failed. See ${log_file}"
  fi
  completed_epoch="$(date -u +%s)"
  wall_seconds=$((completed_epoch - started_epoch))
  [[ -s "$summary_file" ]] || mcqs_fail "No benchmark summary was written: $summary_file"
  write_record "$phase" "$sequence" "$summary_file" \
    "$(date -u -d "@${started_epoch}" +%FT%TZ)" \
    "$(date -u -d "@${completed_epoch}" +%FT%TZ)" \
    "$wall_seconds"
}

RECORD_FILES=()
for sequence in $(seq 1 "$WARMUP_RUNS"); do
  run_one warmup "$sequence"
  RECORD_FILES+=("$RESULTS_DIR/warmup-$(printf '%02d' "$sequence").json")
done
for sequence in $(seq 1 "$MEASURED_RUNS"); do
  run_one measured "$sequence"
  RECORD_FILES+=("$RESULTS_DIR/measured-$(printf '%02d' "$sequence").json")
done

jq -s \
  --arg benchmark_id "$BENCHMARK_ID" \
  --arg profile_id "$PROFILE_ID" \
  --arg architecture "$ARCHITECTURE" \
  --arg spec_file "$SPEC_FILE" \
  '
  def median:
    sort as $values |
    ($values | length) as $count |
    if $count == 0 then null
    elif ($count % 2) == 1 then $values[($count / 2 | floor)]
    else (($values[($count / 2 - 1)] + $values[($count / 2)]) / 2)
    end;
  def p95:
    sort as $values |
    ($values | length) as $count |
    if $count == 0 then null else $values[((($count * 0.95) | ceil) - 1)] end;
  ([.[] | select(.phase == "measured")]) as $measured |
  {
    benchmark_id: $benchmark_id,
    profile_id: $profile_id,
    architecture: $architecture,
    spec_file: $spec_file,
    warmup_runs: ([.[] | select(.phase == "warmup")] | length),
    measured_runs: ($measured | length),
    median_wall_clock_seconds: ($measured | map(.wall_clock_seconds) | median),
    p95_wall_clock_seconds: ($measured | map(.wall_clock_seconds) | p95),
    median_simulations_per_wall_second: ($measured | map(.simulations_per_wall_second) | median),
    median_simulations_per_worker_second: ($measured | map(.simulations_per_worker_second) | median),
    runs: .
  }' "${RECORD_FILES[@]}" \
  > "$RESULTS_DIR/benchmark-summary.json"

jq -r '
  ["benchmark_id", "profile_id", "architecture", "run_id", "phase", "sequence", "wall_clock_seconds", "simulations", "total_worker_seconds", "simulations_per_wall_second", "simulations_per_worker_second", "input_sha256"],
  (.runs[] | [
    .benchmark_id,
    .profile_id,
    .architecture,
    .summary.run_id,
    .phase,
    .sequence,
    .wall_clock_seconds,
    .summary.simulations,
    .summary.total_worker_seconds,
    .simulations_per_wall_second,
    .simulations_per_worker_second,
    .summary.input_sha256
  ]) | @csv' "$RESULTS_DIR/benchmark-summary.json" > "$RESULTS_DIR/benchmark-summary.csv"

mcqs_note "Benchmark complete"
printf 'JSON summary: %s\nCSV summary:  %s\n' \
  "$RESULTS_DIR/benchmark-summary.json" \
  "$RESULTS_DIR/benchmark-summary.csv"
jq '{benchmark_id, profile_id, architecture, measured_runs, median_wall_clock_seconds, p95_wall_clock_seconds, median_simulations_per_wall_second, median_simulations_per_worker_second}' "$RESULTS_DIR/benchmark-summary.json"
