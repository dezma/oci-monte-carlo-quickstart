#!/usr/bin/env bash
set -euo pipefail

# Runs a controlled OCI-OCPU-normalized benchmark. It reserves identical CPU
# and memory for every worker, verifies that two dedicated nodes can honour
# those reservations, and delegates result collection to run-benchmark.sh.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

PROFILE_ID=""
SPEC_FILE="${MCQS_ROOT_DIR}/examples/benchmarks/insurance-savings-throughput-100m.json"
PARALLELISM=6
WARMUP_RUNS=1
MEASURED_RUNS=7
OUTPUT_PARENT="${MCQS_ROOT_DIR}/benchmark-results/strict-ocpu"
BENCHMARK_ID=""
EXPECTED_NODES=2
WORKER_CPU_MILLICORES=2000
WORKER_MEMORY_KIB=$((4 * 1024 * 1024))
VALUES_FILE="${MCQS_ROOT_DIR}/examples/benchmarks/strict-ocpu-values.yaml"

usage() {
  printf '%s\n' "Usage: $0 --profile-id id [--spec file] [--parallelism count] [--warmup-runs count] [--measured-runs count] [--output-parent dir] [--benchmark-id id]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-id) PROFILE_ID="${2:-}"; shift 2 ;;
    --spec) SPEC_FILE="${2:-}"; shift 2 ;;
    --parallelism) PARALLELISM="${2:-}"; shift 2 ;;
    --warmup-runs) WARMUP_RUNS="${2:-}"; shift 2 ;;
    --measured-runs) MEASURED_RUNS="${2:-}"; shift 2 ;;
    --output-parent) OUTPUT_PARENT="${2:-}"; shift 2 ;;
    --benchmark-id) BENCHMARK_ID="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$PROFILE_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  mcqs_fail "profile-id is required and must contain lowercase letters, digits, and hyphens."
[[ -f "$SPEC_FILE" ]] || mcqs_fail "Benchmark spec not found: ${SPEC_FILE}"
[[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "parallelism must be a positive integer."
[[ "$WARMUP_RUNS" =~ ^[0-9]+$ ]] || mcqs_fail "warmup-runs must be zero or a positive integer."
[[ "$MEASURED_RUNS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "measured-runs must be a positive integer."
[[ -f "$VALUES_FILE" ]] || mcqs_fail "Strict benchmark values file is missing: ${VALUES_FILE}"

if [[ -z "$BENCHMARK_ID" ]]; then
  BENCHMARK_ID="strict-ocpu-${PROFILE_ID}-$(date -u +%Y%m%d%H%M%S)"
fi
[[ "$BENCHMARK_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#BENCHMARK_ID} -le 63 ]] || \
  mcqs_fail "benchmark-id must contain lowercase letters, digits, and hyphens (63 characters or fewer)."

mcqs_require_operator_environment
for binary in jq kubectl date; do
  mcqs_require_command "$binary"
done
mcqs_configure_kubeconfig

CONFIG_FILE="${MCQS_BENCHMARK_POOL_CONFIG:-/etc/mcqs-benchmark-pools.json}"
[[ -r "$CONFIG_FILE" ]] || \
  mcqs_fail "Strict OCI-OCPU benchmarking requires Terraform-managed benchmark profile configuration at ${CONFIG_FILE}."
jq -e --arg profile "$PROFILE_ID" '.[$profile] | objects' "$CONFIG_FILE" >/dev/null || \
  mcqs_fail "Benchmark profile ${PROFILE_ID} is not defined in ${CONFIG_FILE}."

ARCHITECTURE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].architecture' "$CONFIG_FILE")"
SELECTOR_KEY="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].selector.key' "$CONFIG_FILE")"
SELECTOR_VALUE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].selector.value' "$CONFIG_FILE")"
TAINT_KEY="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.key // empty' "$CONFIG_FILE")"
TAINT_VALUE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.value // empty' "$CONFIG_FILE")"
TAINT_EFFECT="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.effect // empty' "$CONFIG_FILE")"
[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || \
  mcqs_fail "Profile ${PROFILE_ID} has an invalid architecture."
[[ "$SELECTOR_KEY" != "null" && "$SELECTOR_VALUE" != "null" ]] || \
  mcqs_fail "Profile ${PROFILE_ID} has an incomplete node selector."

# Reapply the profile taint after a worker replacement or scale-out.
"${MCQS_OPERATOR_DIR}/reconcile-benchmark-pools.sh" --profile "$PROFILE_ID" >/dev/null

# FSS is the default result path. Verify the CSI mount on two selected worker
# nodes before spending time on a multi-run comparison. The probe is outside
# benchmark timing and is skipped automatically for the optional Object
# Storage delivery mode.
probe_arguments=(
  --architecture "$ARCHITECTURE"
  --node-selector "${SELECTOR_KEY}=${SELECTOR_VALUE}"
)
if [[ -n "$TAINT_KEY" && -n "$TAINT_VALUE" && "$TAINT_EFFECT" == "NoSchedule" ]]; then
  probe_arguments+=(--toleration "${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}")
fi
"${MCQS_OPERATOR_DIR}/fss-mount-probe.sh" "${probe_arguments[@]}" >/dev/null

mapfile -t NODES < <(
  kubectl get nodes -l "${SELECTOR_KEY}=${SELECTOR_VALUE}" -o json | jq -r --arg architecture "$ARCHITECTURE" '
    .items[]
    | select(.metadata.labels["kubernetes.io/arch"] == $architecture)
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name
  '
)
(( ${#NODES[@]} == EXPECTED_NODES )) || \
  mcqs_fail "Strict OCI-OCPU benchmarking requires exactly ${EXPECTED_NODES} Ready ${ARCHITECTURE} nodes for ${PROFILE_ID}; found ${#NODES[@]}. Pin pool capacity before retrying."

# maxSkew=1 across two hosts gives this maximum reservation on either node.
WORKERS_PER_NODE=$(( (PARALLELISM + EXPECTED_NODES - 1) / EXPECTED_NODES ))
REQUIRED_CPU_MILLICORES=$(( WORKERS_PER_NODE * WORKER_CPU_MILLICORES ))
REQUIRED_MEMORY_KIB=$(( WORKERS_PER_NODE * WORKER_MEMORY_KIB ))

for node in "${NODES[@]}"; do
  allocatable_cpu="$(kubectl get node "$node" -o jsonpath='{.status.allocatable.cpu}')"
  allocatable_memory="$(kubectl get node "$node" -o jsonpath='{.status.allocatable.memory}')"
  if [[ "$allocatable_cpu" =~ ^([0-9]+)m$ ]]; then
    allocatable_cpu_millicores="${BASH_REMATCH[1]}"
  elif [[ "$allocatable_cpu" =~ ^[0-9]+$ ]]; then
    allocatable_cpu_millicores=$(( allocatable_cpu * 1000 ))
  else
    mcqs_fail "Cannot interpret allocatable CPU '${allocatable_cpu}' on node ${node}."
  fi
  if [[ "$allocatable_memory" =~ ^([0-9]+)Ki$ ]]; then
    allocatable_memory_kib="${BASH_REMATCH[1]}"
  else
    mcqs_fail "Cannot interpret allocatable memory '${allocatable_memory}' on node ${node}."
  fi
  (( allocatable_cpu_millicores >= REQUIRED_CPU_MILLICORES )) || \
    mcqs_fail "Node ${node} has ${allocatable_cpu_millicores}m allocatable CPU, but ${WORKERS_PER_NODE} strict workers require ${REQUIRED_CPU_MILLICORES}m. Reduce parallelism or increase node OCPUs."
  (( allocatable_memory_kib >= REQUIRED_MEMORY_KIB )) || \
    mcqs_fail "Node ${node} has ${allocatable_memory_kib}Ki allocatable memory, but ${WORKERS_PER_NODE} strict workers require ${REQUIRED_MEMORY_KIB}Ki. Reduce parallelism or increase node memory."
done

mcqs_note "Strict OCI-OCPU-normalized benchmark plan"
printf 'Profile: %s (%s)\nNodes: %s\nWorkers: %s (%s per node)\nReserved per worker: 2 CPU, 4Gi memory\n' \
  "$PROFILE_ID" "$ARCHITECTURE" "$EXPECTED_NODES" "$PARALLELISM" "$WORKERS_PER_NODE"

"${MCQS_OPERATOR_DIR}/run-benchmark.sh" \
  --spec "$SPEC_FILE" \
  --profile-id "$PROFILE_ID" \
  --architecture "$ARCHITECTURE" \
  --parallelism "$PARALLELISM" \
  --warmup-runs "$WARMUP_RUNS" \
  --measured-runs "$MEASURED_RUNS" \
  --values "$VALUES_FILE" \
  --output-parent "$OUTPUT_PARENT" \
  --benchmark-id "$BENCHMARK_ID"
