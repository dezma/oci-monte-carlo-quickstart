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

mcqs_note "Installing the secure runtime baseline"
helm upgrade --install monte-carlo "$MCQS_HELM_DIR" \
  --namespace "$MCQS_NAMESPACE" \
  --create-namespace \
  --atomic \
  --set namespace.create=false \
  --set namespace.name="$MCQS_NAMESPACE" \
  --set serviceAccount.create=true \
  --set serviceAccount.name="$MCQS_SERVICE_ACCOUNT"

kubectl -n "$MCQS_NAMESPACE" get serviceaccount "$MCQS_SERVICE_ACCOUNT" >/dev/null
printf '\nRuntime baseline installed. Build an immutable image and rotate the OCIR pull secret next.\n'
