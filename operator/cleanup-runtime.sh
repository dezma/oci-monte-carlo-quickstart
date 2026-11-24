#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nRemoves Monte Carlo Helm releases only. The namespace and OCIR pull secret are retained.\n' "$0"
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

mcqs_note "Removing Helm releases only; the namespace and OCIR pull secret are retained"
while IFS= read -r release; do
  [[ -z "$release" ]] || helm uninstall "$release" --namespace "$MCQS_NAMESPACE"
done < <(helm list --namespace "$MCQS_NAMESPACE" --short --filter '^(monte-carlo|mc-run-)')

printf 'Runtime releases removed. Delete the namespace manually only after confirming it contains no customer workloads.\n'
