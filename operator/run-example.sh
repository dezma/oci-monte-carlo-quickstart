#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

SPEC_FILE="${MCQS_ROOT_DIR}/examples/sample-simulation.json"
PARALLELISM=4
ARCHITECTURE="${MCQS_NODE_ARCHITECTURE:-amd64}"
MAX_PARALLELISM="${MCQS_MAX_PARALLELISM:-32}"
WAIT_FOR_COMPLETION=true
SHOW_PROGRESS=true
PROGRESS_INTERVAL_SECONDS="${MCQS_PROGRESS_INTERVAL_SECONDS:-5}"
QUEUE_NAME=""
GRID_ID=""
SCENARIO_ID=""
VALUES_FILE=""
SUMMARY_FILE=""
RUN_ID_PREFIX=""
BENCHMARK_ID=""
BENCHMARK_PROFILE=""
BENCHMARK_PHASE=""
NODE_SELECTORS=()
TOLERATIONS=()
TOPOLOGY_SPREAD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec)
      SPEC_FILE="${2:-}"
      shift 2
      ;;
    --parallelism)
      PARALLELISM="${2:-}"
      shift 2
      ;;
    --architecture)
      ARCHITECTURE="${2:-}"
      shift 2
      ;;
    --queue-name)
      QUEUE_NAME="${2:-}"
      shift 2
      ;;
    --grid-id)
      GRID_ID="${2:-}"
      shift 2
      ;;
    --scenario-id)
      SCENARIO_ID="${2:-}"
      shift 2
      ;;
    --values)
      VALUES_FILE="${2:-}"
      shift 2
      ;;
    --node-selector)
      NODE_SELECTORS+=("${2:-}")
      shift 2
      ;;
    --toleration)
      TOLERATIONS+=("${2:-}")
      shift 2
      ;;
    --topology-spread)
      TOPOLOGY_SPREAD=true
      shift
      ;;
    --summary-file)
      SUMMARY_FILE="${2:-}"
      shift 2
      ;;
    --run-id-prefix)
      RUN_ID_PREFIX="${2:-}"
      shift 2
      ;;
    --benchmark-id)
      BENCHMARK_ID="${2:-}"
      shift 2
      ;;
    --benchmark-profile)
      BENCHMARK_PROFILE="${2:-}"
      shift 2
      ;;
    --benchmark-phase)
      BENCHMARK_PHASE="${2:-}"
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_COMPLETION=false
      shift
      ;;
    --no-progress)
      SHOW_PROGRESS=false
      shift
      ;;
    --progress-interval)
      PROGRESS_INTERVAL_SECONDS="${2:-}"
      shift 2
      ;;
    --help|-h)
      printf 'Usage: %s [--spec file] [--parallelism count] [--architecture amd64|arm64] [--node-selector key=value] [--toleration key=value:NoSchedule] [--topology-spread] [--queue-name name] [--grid-id id --scenario-id id] [--values file] [--summary-file file] [--run-id-prefix id] [--benchmark-id id --benchmark-profile id --benchmark-phase warmup|measured] [--progress-interval seconds|--no-progress] [--no-wait]\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

[[ -f "$SPEC_FILE" ]] || mcqs_fail "Simulation spec not found: $SPEC_FILE"
[[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "parallelism must be a positive integer."
[[ "$PROGRESS_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "progress-interval must be a positive integer."
[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || mcqs_fail "architecture must be amd64 or arm64."
[[ -z "$QUEUE_NAME" || "$QUEUE_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || mcqs_fail "queue-name must be a valid Kubernetes label value."
[[ -z "$GRID_ID" || "$GRID_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "grid-id must contain lowercase letters, digits, and hyphens."
[[ -z "$SCENARIO_ID" || "$SCENARIO_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "scenario-id must contain lowercase letters, digits, and hyphens."
[[ -z "$GRID_ID" || -n "$SCENARIO_ID" ]] || mcqs_fail "scenario-id is required when grid-id is set."
[[ -z "$SCENARIO_ID" || -n "$GRID_ID" ]] || mcqs_fail "grid-id is required when scenario-id is set."
[[ -z "$VALUES_FILE" || -f "$VALUES_FILE" ]] || mcqs_fail "Helm values file not found: $VALUES_FILE"
[[ -z "$SUMMARY_FILE" || -d "$(dirname "$SUMMARY_FILE")" ]] || \
  mcqs_fail "The directory for summary-file does not exist: $(dirname "$SUMMARY_FILE")"
[[ -z "$RUN_ID_PREFIX" || "$RUN_ID_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || \
  mcqs_fail "run-id-prefix must contain only letters, numbers, hyphens, and underscores (48 characters or fewer)."
[[ -z "$BENCHMARK_ID" || "$BENCHMARK_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  mcqs_fail "benchmark-id must contain lowercase letters, digits, and hyphens."
[[ -z "$BENCHMARK_PROFILE" || "$BENCHMARK_PROFILE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  mcqs_fail "benchmark-profile must contain lowercase letters, digits, and hyphens."
[[ -z "$BENCHMARK_PHASE" || "$BENCHMARK_PHASE" == "warmup" || "$BENCHMARK_PHASE" == "measured" ]] || \
  mcqs_fail "benchmark-phase must be warmup or measured."
[[ -z "$BENCHMARK_ID" || -n "$BENCHMARK_PROFILE" ]] || \
  mcqs_fail "benchmark-profile is required when benchmark-id is set."
[[ -z "$BENCHMARK_PROFILE" || -n "$BENCHMARK_ID" ]] || \
  mcqs_fail "benchmark-id is required when benchmark-profile is set."
[[ -z "$BENCHMARK_PHASE" || -n "$BENCHMARK_ID" ]] || \
  mcqs_fail "benchmark-id is required when benchmark-phase is set."
[[ "$TOPOLOGY_SPREAD" != true || -n "$BENCHMARK_ID" ]] || \
  mcqs_fail "topology-spread is reserved for benchmark runs; use operator/run-benchmark.sh."
if [[ -n "${MCQS_NODE_ARCHITECTURE:-}" && "$ARCHITECTURE" != "$MCQS_NODE_ARCHITECTURE" && -z "$BENCHMARK_ID" ]]; then
  mcqs_fail "architecture ${ARCHITECTURE} does not match this quickstart node pool (${MCQS_NODE_ARCHITECTURE}). Re-provision or use a matching architecture."
fi
[[ "$MAX_PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "MCQS_MAX_PARALLELISM must be a positive integer."
(( PARALLELISM <= MAX_PARALLELISM )) || mcqs_fail "parallelism exceeds the safe quickstart limit (${MAX_PARALLELISM}). Set MCQS_MAX_PARALLELISM explicitly after reviewing capacity and cost."
SPEC_SIMULATIONS="$(jq -r '.simulations // empty' "$SPEC_FILE")"
[[ "$SPEC_SIMULATIONS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "spec.simulations must be a positive integer."
(( PARALLELISM <= SPEC_SIMULATIONS )) || mcqs_fail "parallelism cannot exceed simulations in the supplied spec."
for selector in "${NODE_SELECTORS[@]}"; do
  selector_key="${selector%%=*}"
  selector_value="${selector#*=}"
  [[ "$selector" == *=* && -n "$selector_key" && -n "$selector_value" ]] || \
    mcqs_fail "node-selector must use key=value syntax."
  [[ "$selector_key" =~ ^[A-Za-z0-9._/-]+$ && "$selector_value" =~ ^[A-Za-z0-9._-]+$ ]] || \
    mcqs_fail "node-selector contains unsupported characters."
done
for toleration in "${TOLERATIONS[@]}"; do
  toleration_pair="${toleration%:*}"
  toleration_effect="${toleration##*:}"
  toleration_key="${toleration_pair%%=*}"
  toleration_value="${toleration_pair#*=}"
  [[ "$toleration" == *=*:* && -n "$toleration_key" && -n "$toleration_value" ]] || \
    mcqs_fail "toleration must use key=value:NoSchedule, key=value:PreferNoSchedule, or key=value:NoExecute syntax."
  [[ "$toleration_key" =~ ^[A-Za-z0-9._/-]+$ && "$toleration_value" =~ ^[A-Za-z0-9._-]+$ ]] || \
    mcqs_fail "toleration contains unsupported key or value characters."
  [[ "$toleration_effect" == "NoSchedule" || "$toleration_effect" == "PreferNoSchedule" || "$toleration_effect" == "NoExecute" ]] || \
    mcqs_fail "toleration effect must be NoSchedule, PreferNoSchedule, or NoExecute."
done
WORKLOAD_TYPE="$(jq -r '.workload_type // "option_pricing"' "$SPEC_FILE")"
[[ "$WORKLOAD_TYPE" == "option_pricing" || "$WORKLOAD_TYPE" == "insurance_savings" ]] || \
  mcqs_fail "spec.workload_type must be option_pricing or insurance_savings."
MCQS_PYTHON="${MCQS_PYTHON:-python3}"
for binary in helm kubectl jq "$MCQS_PYTHON"; do
  mcqs_require_command "$binary"
done

mcqs_require_operator_environment

mcqs_configure_kubeconfig
mcqs_load_image_metadata
mcqs_require_value MCQS_IMAGE_REPOSITORY
mcqs_require_value MCQS_IMAGE_DIGEST

MCQS_RESULT_DELIVERY_MODE="${MCQS_RESULT_DELIVERY_MODE:-fss}"
HELM_RESULT_DELIVERY_ARGS=(--set "resultDelivery.mode=${MCQS_RESULT_DELIVERY_MODE}")
case "$MCQS_RESULT_DELIVERY_MODE" in
  object_storage)
    MCQS_OBJECT_STORAGE_BUCKET="${MCQS_OBJECT_STORAGE_BUCKET:-}"
    MCQS_OBJECT_STORAGE_NAMESPACE="${MCQS_OBJECT_STORAGE_NAMESPACE:-}"
    MCQS_OBJECT_STORAGE_PREFIX="${MCQS_OBJECT_STORAGE_PREFIX:-monte-carlo}"
    MCQS_REGION="${OCI_REGION:-${REGION:-${MCQS_REGION:-}}}"
    mcqs_require_value MCQS_OBJECT_STORAGE_BUCKET
    mcqs_require_value MCQS_OBJECT_STORAGE_NAMESPACE
    mcqs_require_value MCQS_REGION
    HELM_RESULT_DELIVERY_ARGS+=(
      --set "objectStorage.bucket=${MCQS_OBJECT_STORAGE_BUCKET}"
      --set "objectStorage.namespace=${MCQS_OBJECT_STORAGE_NAMESPACE}"
      --set "objectStorage.prefix=${MCQS_OBJECT_STORAGE_PREFIX}"
      --set "objectStorage.region=${MCQS_REGION}"
    )
    ;;
  fss)
    MCQS_FSS_RESULTS_DIR="${MCQS_FSS_RESULTS_DIR:-}"
    MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME="${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME:-monte-carlo-results}"
    mcqs_require_value MCQS_FSS_RESULTS_DIR
    mountpoint -q "$MCQS_FSS_RESULTS_DIR" || \
      mcqs_fail "FSS result delivery is configured but ${MCQS_FSS_RESULTS_DIR} is not mounted. Run operator/doctor.sh."
    HELM_RESULT_DELIVERY_ARGS+=(
      --set-string "resultDelivery.fss.claimName=${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME}"
    )
    ;;
  *)
    mcqs_fail "MCQS_RESULT_DELIVERY_MODE must be object_storage or fss."
    ;;
esac
MCQS_RUN_ID_BASE="${RUN_ID_PREFIX:-$(jq -r '.run_id' "$SPEC_FILE")}"
MCQS_RUN_ID="${MCQS_RUN_ID_BASE}-$(date -u +%Y%m%d%H%M%S)"
MCQS_RUN_ID="${MCQS_RUN_ID:0:40}"
MCQS_RELEASE="mc-run-${MCQS_RUN_ID}"
MCQS_SPEC_COPY="$(mktemp)"
trap 'rm -f "$MCQS_SPEC_COPY"' EXIT
jq --arg run_id "$MCQS_RUN_ID" '.run_id = $run_id' "$SPEC_FILE" > "$MCQS_SPEC_COPY"

HELM_VALUES_ARGS=()
if [[ -n "$VALUES_FILE" ]]; then
  HELM_VALUES_ARGS=(-f "$VALUES_FILE")
fi

HELM_SELECTOR_ARGS=(
  --set-string "nodeSelector.kubernetes\\.io/arch=${ARCHITECTURE}"
)
for selector in "${NODE_SELECTORS[@]}"; do
  selector_key="${selector%%=*}"
  selector_value="${selector#*=}"
  helm_selector_key="${selector_key//./\\.}"
  HELM_SELECTOR_ARGS+=(--set-string "nodeSelector.${helm_selector_key}=${selector_value}")
done

HELM_TOLERATION_ARGS=()
for index in "${!TOLERATIONS[@]}"; do
  toleration="${TOLERATIONS[$index]}"
  toleration_pair="${toleration%:*}"
  toleration_effect="${toleration##*:}"
  toleration_key="${toleration_pair%%=*}"
  toleration_value="${toleration_pair#*=}"
  helm_toleration_key="${toleration_key//./\\.}"
  HELM_TOLERATION_ARGS+=(
    --set-string "tolerations[$index].key=${helm_toleration_key}"
    --set-string "tolerations[$index].operator=Equal"
    --set-string "tolerations[$index].value=${toleration_value}"
    --set-string "tolerations[$index].effect=${toleration_effect}"
  )
done

HELM_TOPOLOGY_SPREAD_ARGS=()
if [[ "$TOPOLOGY_SPREAD" == true ]]; then
  HELM_TOPOLOGY_SPREAD_ARGS=(--set run.topologySpread.enabled=true)
fi

kubectl -n "$MCQS_NAMESPACE" get serviceaccount "$MCQS_SERVICE_ACCOUNT" >/dev/null || mcqs_fail "Runtime baseline is missing. Run operator/install-runtime.sh first."
if [[ "$MCQS_RESULT_DELIVERY_MODE" == "fss" ]]; then
  kubectl -n "$MCQS_NAMESPACE" get pvc "$MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME" >/dev/null || \
    mcqs_fail "FSS PersistentVolumeClaim is missing. Run operator/install-runtime.sh after provisioning FSS."
  [[ "$(kubectl -n "$MCQS_NAMESPACE" get pvc "$MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME" -o jsonpath='{.status.phase}')" == "Bound" ]] || \
    mcqs_fail "FSS PersistentVolumeClaim is not Bound. Check the FSS CSI driver, FSS network rules, and operator/doctor.sh."
fi

mcqs_note "Submitting Indexed Job ${MCQS_RUN_ID}"
helm upgrade --install "$MCQS_RELEASE" "$MCQS_HELM_DIR" \
  --namespace "$MCQS_NAMESPACE" \
  "${HELM_VALUES_ARGS[@]}" \
  --set namespace.create=false \
  --set namespace.name="$MCQS_NAMESPACE" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$MCQS_SERVICE_ACCOUNT" \
  --set image.repository="$MCQS_IMAGE_REPOSITORY" \
  --set image.digest="$MCQS_IMAGE_DIGEST" \
  "${HELM_RESULT_DELIVERY_ARGS[@]}" \
  "${HELM_SELECTOR_ARGS[@]}" \
  "${HELM_TOLERATION_ARGS[@]}" \
  "${HELM_TOPOLOGY_SPREAD_ARGS[@]}" \
  --set run.enabled=true \
  --set run.id="$MCQS_RUN_ID" \
  --set run.parallelism="$PARALLELISM" \
  --set run.queueName="$QUEUE_NAME" \
  --set run.gridId="$GRID_ID" \
  --set run.scenarioId="$SCENARIO_ID" \
  --set-string run.benchmarkId="$BENCHMARK_ID" \
  --set-string run.benchmarkProfile="$BENCHMARK_PROFILE" \
  --set-string run.benchmarkPhase="$BENCHMARK_PHASE" \
  --set-file run.specJson="$MCQS_SPEC_COPY"

MCQS_JOB="$(kubectl -n "$MCQS_NAMESPACE" get jobs -l "monte-carlo.oracle.com/run-id=${MCQS_RUN_ID}" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$MCQS_JOB" ]] || mcqs_fail "Helm reported success but no simulation Job was found."

if [[ "$WAIT_FOR_COMPLETION" != true ]]; then
  printf 'Submitted run %s as Job %s.\n' "$MCQS_RUN_ID" "$MCQS_JOB"
  printf 'Monitor it with: %s/watch-run.sh --job %q --run-id %q --partitions %q\n' \
    "$MCQS_OPERATOR_DIR" "$MCQS_JOB" "$MCQS_RUN_ID" "$PARALLELISM"
  exit 0
fi

if [[ "$SHOW_PROGRESS" == true ]]; then
  WAIT_COMMAND=(
    "$MCQS_OPERATOR_DIR/watch-run.sh"
    --job "$MCQS_JOB"
    --run-id "$MCQS_RUN_ID"
    --partitions "$PARALLELISM"
    --interval "$PROGRESS_INTERVAL_SECONDS"
    --timeout "${MCQS_WAIT_TIMEOUT:-20m}"
  )
else
  WAIT_COMMAND=(kubectl -n "$MCQS_NAMESPACE" wait --for=condition=complete "job/${MCQS_JOB}" --timeout="${MCQS_WAIT_TIMEOUT:-20m}")
fi

if ! "${WAIT_COMMAND[@]}"; then
  kubectl -n "$MCQS_NAMESPACE" describe "job/${MCQS_JOB}" || true
  kubectl -n "$MCQS_NAMESPACE" get pods -l "monte-carlo.oracle.com/run-id=${MCQS_RUN_ID}" -o wide || true
  kubectl -n "$MCQS_NAMESPACE" logs -l "monte-carlo.oracle.com/run-id=${MCQS_RUN_ID}" --all-containers=true --prefix --tail=-1 || true
  mcqs_fail "Simulation job did not complete successfully."
fi

mcqs_note "Aggregating immutable partial results"
AGGREGATOR="${MCQS_OPERATOR_DIR}/aggregate-results.sh"
if [[ "$WORKLOAD_TYPE" == "insurance_savings" ]]; then
  AGGREGATOR="${MCQS_OPERATOR_DIR}/aggregate-insurance-savings-results.sh"
fi
SUMMARY="$("$AGGREGATOR" \
  --run-id "$MCQS_RUN_ID" \
  --expected-partitions "$PARALLELISM" \
  --confidence "$(jq -r '.confidence_level' "$MCQS_SPEC_COPY")")"
printf '%s\n' "$SUMMARY"
if [[ -n "$SUMMARY_FILE" ]]; then
  umask 077
  printf '%s\n' "$SUMMARY" > "$SUMMARY_FILE"
fi
