#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nInstalls or upgrades the shared secure runtime baseline on the private OKE cluster. Run only from the provisioned operator instance.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_require_command helm
mcqs_require_command kubectl
mcqs_require_operator_environment
mcqs_configure_kubeconfig

MCQS_RESULT_DELIVERY_MODE="${MCQS_RESULT_DELIVERY_MODE:-fss}"
HELM_RESULT_DELIVERY_ARGS=(--set "resultDelivery.mode=${MCQS_RESULT_DELIVERY_MODE}")
case "$MCQS_RESULT_DELIVERY_MODE" in
  object_storage)
    ;;
  fss)
    MCQS_FSS_VOLUME_HANDLE="${MCQS_FSS_VOLUME_HANDLE:-}"
    MCQS_FSS_PERSISTENT_VOLUME_NAME="${MCQS_FSS_PERSISTENT_VOLUME_NAME:-}"
    MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME="${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME:-monte-carlo-results}"
    MCQS_FSS_PERSISTENT_VOLUME_CAPACITY="${MCQS_FSS_PERSISTENT_VOLUME_CAPACITY:-50Gi}"
    MCQS_FSS_RESULTS_DIR="${MCQS_FSS_RESULTS_DIR:-}"
    mcqs_require_value MCQS_FSS_VOLUME_HANDLE
    mcqs_require_value MCQS_FSS_PERSISTENT_VOLUME_NAME
    mcqs_require_value MCQS_FSS_RESULTS_DIR
    mountpoint -q "$MCQS_FSS_RESULTS_DIR" || \
      mcqs_fail "FSS result delivery is configured but ${MCQS_FSS_RESULTS_DIR} is not mounted. Review operator/doctor.sh."
    kubectl get csidriver fss.csi.oraclecloud.com >/dev/null || \
      mcqs_fail "The OKE FSS CSI driver is unavailable. Enable or repair the OKE File Storage CSI add-on before installing the FSS runtime."
    HELM_RESULT_DELIVERY_ARGS+=(
      --set-string "resultDelivery.fss.volumeHandle=${MCQS_FSS_VOLUME_HANDLE}"
      --set-string "resultDelivery.fss.persistentVolumeName=${MCQS_FSS_PERSISTENT_VOLUME_NAME}"
      --set-string "resultDelivery.fss.claimName=${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME}"
      --set-string "resultDelivery.fss.capacity=${MCQS_FSS_PERSISTENT_VOLUME_CAPACITY}"
    )
    ;;
  *)
    mcqs_fail "MCQS_RESULT_DELIVERY_MODE must be object_storage or fss."
    ;;
esac

mcqs_note "Installing the secure runtime baseline"
helm upgrade --install monte-carlo "$MCQS_HELM_DIR" \
  --namespace "$MCQS_NAMESPACE" \
  --create-namespace \
  --atomic \
  --set namespace.create=false \
  --set namespace.name="$MCQS_NAMESPACE" \
  --set serviceAccount.create=true \
  --set serviceAccount.name="$MCQS_SERVICE_ACCOUNT" \
  "${HELM_RESULT_DELIVERY_ARGS[@]}"

kubectl -n "$MCQS_NAMESPACE" get serviceaccount "$MCQS_SERVICE_ACCOUNT" >/dev/null
if [[ "$MCQS_RESULT_DELIVERY_MODE" == "fss" ]]; then
  kubectl -n "$MCQS_NAMESPACE" wait \
    --for=jsonpath='{.status.phase}'=Bound \
    "pvc/${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME}" \
    --timeout=2m >/dev/null || \
    mcqs_fail "FSS result claim ${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME} did not become Bound. Check the FSS CSI driver and runtime baseline."
  printf 'FSS result claim: %s (Bound)\n' "$MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME"
fi
printf '\nRuntime baseline installed. Build an immutable image and rotate the OCIR pull secret next.\n'
