#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nShows Monte Carlo Jobs and recent worker pods after configuring private OKE access.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_require_operator_environment
mcqs_configure_kubeconfig
mcqs_note "Monte Carlo jobs"
kubectl -n "$MCQS_NAMESPACE" get jobs -l app.kubernetes.io/name=monte-carlo
mcqs_note "Recent Monte Carlo pods"
kubectl -n "$MCQS_NAMESPACE" get pods -l app.kubernetes.io/name=monte-carlo --sort-by=.status.startTime
