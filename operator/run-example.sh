#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

SPEC_FILE="${MCQS_ROOT_DIR}/examples/sample-simulation.json"
PARALLELISM=4
ARCHITECTURE="${MCQS_NODE_ARCHITECTURE:-amd64}"
MAX_PARALLELISM="${MCQS_MAX_PARALLELISM:-32}"

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
    --help|-h)
      printf 'Usage: %s [--spec file] [--parallelism count] [--architecture amd64|arm64]\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

[[ -f "$SPEC_FILE" ]] || mcqs_fail "Simulation spec not found: $SPEC_FILE"
[[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "parallelism must be a positive integer."
[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || mcqs_fail "architecture must be amd64 or arm64."
if [[ -n "${MCQS_NODE_ARCHITECTURE:-}" && "$ARCHITECTURE" != "$MCQS_NODE_ARCHITECTURE" ]]; then
  mcqs_fail "architecture ${ARCHITECTURE} does not match this quickstart node pool (${MCQS_NODE_ARCHITECTURE}). Re-provision or use a matching architecture."
fi
[[ "$MAX_PARALLELISM" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "MCQS_MAX_PARALLELISM must be a positive integer."
(( PARALLELISM <= MAX_PARALLELISM )) || mcqs_fail "parallelism exceeds the safe quickstart limit (${MAX_PARALLELISM}). Set MCQS_MAX_PARALLELISM explicitly after reviewing capacity and cost."
SPEC_SIMULATIONS="$(jq -r '.simulations // empty' "$SPEC_FILE")"
[[ "$SPEC_SIMULATIONS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "spec.simulations must be a positive integer."
(( PARALLELISM <= SPEC_SIMULATIONS )) || mcqs_fail "parallelism cannot exceed simulations in the supplied spec."
MCQS_PYTHON="${MCQS_PYTHON:-python3}"
for binary in helm kubectl jq "$MCQS_PYTHON"; do
  mcqs_require_command "$binary"
done

mcqs_require_operator_environment

mcqs_configure_kubeconfig
mcqs_load_image_metadata
mcqs_require_value MCQS_IMAGE_REPOSITORY
mcqs_require_value MCQS_IMAGE_DIGEST

MCQS_OBJECT_STORAGE_BUCKET="${MCQS_OBJECT_STORAGE_BUCKET:-}"
MCQS_OBJECT_STORAGE_NAMESPACE="${MCQS_OBJECT_STORAGE_NAMESPACE:-}"
MCQS_OBJECT_STORAGE_PREFIX="${MCQS_OBJECT_STORAGE_PREFIX:-monte-carlo}"
MCQS_REGION="${OCI_REGION:-${REGION:-${MCQS_REGION:-}}}"
mcqs_require_value MCQS_OBJECT_STORAGE_BUCKET
mcqs_require_value MCQS_OBJECT_STORAGE_NAMESPACE
mcqs_require_value MCQS_REGION
MCQS_RUN_ID="$(jq -r '.run_id' "$SPEC_FILE")-$(date -u +%Y%m%d%H%M%S)"
MCQS_RUN_ID="${MCQS_RUN_ID:0:40}"
MCQS_RELEASE="mc-run-${MCQS_RUN_ID}"
MCQS_SPEC_COPY="$(mktemp)"
trap 'rm -f "$MCQS_SPEC_COPY"' EXIT
jq --arg run_id "$MCQS_RUN_ID" '.run_id = $run_id' "$SPEC_FILE" > "$MCQS_SPEC_COPY"

kubectl -n "$MCQS_NAMESPACE" get serviceaccount "$MCQS_SERVICE_ACCOUNT" >/dev/null || mcqs_fail "Runtime baseline is missing. Run operator/install-runtime.sh first."

mcqs_note "Submitting Indexed Job ${MCQS_RUN_ID}"
helm upgrade --install "$MCQS_RELEASE" "$MCQS_HELM_DIR" \
  --namespace "$MCQS_NAMESPACE" \
  --set namespace.create=false \
  --set namespace.name="$MCQS_NAMESPACE" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$MCQS_SERVICE_ACCOUNT" \
  --set image.repository="$MCQS_IMAGE_REPOSITORY" \
  --set image.digest="$MCQS_IMAGE_DIGEST" \
  --set objectStorage.bucket="$MCQS_OBJECT_STORAGE_BUCKET" \
  --set objectStorage.namespace="$MCQS_OBJECT_STORAGE_NAMESPACE" \
  --set objectStorage.prefix="$MCQS_OBJECT_STORAGE_PREFIX" \
  --set objectStorage.region="$MCQS_REGION" \
  --set nodeSelector.kubernetes\\.io/arch="$ARCHITECTURE" \
  --set run.enabled=true \
  --set run.id="$MCQS_RUN_ID" \
  --set run.parallelism="$PARALLELISM" \
  --set-file run.specJson="$MCQS_SPEC_COPY"

MCQS_JOB="$(kubectl -n "$MCQS_NAMESPACE" get jobs -l "monte-carlo.oracle.com/run-id=${MCQS_RUN_ID}" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$MCQS_JOB" ]] || mcqs_fail "Helm reported success but no simulation Job was found."

if ! kubectl -n "$MCQS_NAMESPACE" wait --for=condition=complete "job/${MCQS_JOB}" --timeout="${MCQS_WAIT_TIMEOUT:-20m}"; then
  kubectl -n "$MCQS_NAMESPACE" describe "job/${MCQS_JOB}" || true
  kubectl -n "$MCQS_NAMESPACE" get pods -l "monte-carlo.oracle.com/run-id=${MCQS_RUN_ID}" -o wide || true
  kubectl -n "$MCQS_NAMESPACE" logs -l "monte-carlo.oracle.com/run-id=${MCQS_RUN_ID}" --all-containers=true --prefix --tail=-1 || true
  mcqs_fail "Simulation job did not complete successfully."
fi

mcqs_note "Aggregating immutable partial results"
"${MCQS_OPERATOR_DIR}/aggregate-results.sh" \
  --run-id "$MCQS_RUN_ID" \
  --expected-partitions "$PARALLELISM" \
  --confidence "$(jq -r '.confidence_level' "$MCQS_SPEC_COPY")"
