#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nChecks bootstrap state, instance-principal access, operator tools, and private OKE connectivity. Run after sourcing /etc/profile.d/mcqs-runtime.sh.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_note "Checking operator bootstrap state"
for status_file in \
  /var/lib/mcqs/operator-bootstrap-status.json \
  /var/lib/mcqs/bootstrap-status.json; do
  if [[ -r "$status_file" ]]; then
    printf 'Bootstrap status (%s):\n' "$status_file"
    cat "$status_file"
    printf '\n'
    break
  fi
done
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --long || true
fi

mcqs_require_operator_environment

mcqs_note "Checking installed tooling"
MCQS_PYTHON="${MCQS_PYTHON:-python3}"
for binary in oci kubectl helm jq "$MCQS_PYTHON"; do
  mcqs_require_command "$binary"
done
command -v docker >/dev/null 2>&1 || mcqs_fail "Docker is not installed. Review /var/log/mcqs-operator-bootstrap.log."
printf 'OCI CLI: %s\n' "$(oci --version)"
printf 'kubectl: %s\n' "$(kubectl version --client --output=json | jq -r '.clientVersion.gitVersion')"
printf 'Helm: %s\n' "$(helm version --short)"
printf 'Node architecture: %s\n' "${MCQS_NODE_ARCHITECTURE:-amd64}"

mcqs_note "Checking OCI instance-principal access"
oci os ns get --query data --raw-output >/dev/null || \
  mcqs_fail "OCI instance-principal authentication failed. Wait for IAM propagation or review the operator dynamic-group policy."
printf 'OCI instance principal: ready\n'

mcqs_note "Checking private OKE connectivity"
mcqs_configure_kubeconfig
kubectl cluster-info

if [[ "${MCQS_RESULT_DELIVERY_MODE:-fss}" == "fss" ]]; then
  mcqs_note "Checking private FSS result delivery"
  MCQS_FSS_RESULTS_DIR="${MCQS_FSS_RESULTS_DIR:-}"
  mcqs_require_value MCQS_FSS_RESULTS_DIR
  mountpoint -q "$MCQS_FSS_RESULTS_DIR" || \
    mcqs_fail "FSS results are not mounted at ${MCQS_FSS_RESULTS_DIR}. Review /var/log/mcqs-operator-bootstrap.log."
  kubectl get csidriver fss.csi.oraclecloud.com >/dev/null || \
    mcqs_fail "The OKE FSS CSI driver is unavailable. Enable or repair the OKE File Storage CSI add-on."
  printf 'FSS results: mounted at %s\n' "$MCQS_FSS_RESULTS_DIR"
  if kubectl -n "$MCQS_NAMESPACE" get pvc "${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME:-}" >/dev/null 2>&1; then
    [[ "$(kubectl -n "$MCQS_NAMESPACE" get pvc "$MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME" -o jsonpath='{.status.phase}')" == "Bound" ]] || \
      mcqs_fail "FSS runtime claim ${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME} is not Bound. Run operator/install-runtime.sh and check the FSS CSI driver."
    printf 'FSS runtime claim: %s (Bound)\n' "$MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME"
  else
    printf 'FSS runtime claim: not installed yet; run operator/install-runtime.sh\n'
  fi
fi

printf '\nOperator is ready. Next run operator/install-runtime.sh, publish an immutable image, create the pull secret, and submit a job.\n'
