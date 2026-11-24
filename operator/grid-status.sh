#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

GRID_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --grid-id) GRID_ID="${2:-}"; shift 2 ;;
    --help|-h)
      printf 'Usage: %s --grid-id <grid-id>\n' "$0"
      exit 0
      ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$GRID_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "grid-id must contain lowercase letters, digits, and hyphens."
mcqs_require_command kubectl
mcqs_require_operator_environment
mcqs_configure_kubeconfig

kubectl -n "$MCQS_NAMESPACE" get jobs,pods \
  -l "monte-carlo.oracle.com/grid-id=${GRID_ID}" \
  -o wide

if kubectl api-resources --api-group=kueue.x-k8s.io -o name 2>/dev/null | grep -qx workloads.kueue.x-k8s.io; then
  printf '\nKueue workloads:\n'
  kubectl -n "$MCQS_NAMESPACE" get workloads \
    -l "monte-carlo.oracle.com/grid-id=${GRID_ID}" -o wide
fi
