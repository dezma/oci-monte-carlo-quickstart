#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

NAMESPACE="mcqs-observability"
RELEASE="mcqs-observability"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --help|-h)
      printf '%s\n' "Usage: $0 [--namespace name] [--release name]"
      exit 0
      ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

mcqs_require_operator_environment
for binary in helm kubectl; do mcqs_require_command "$binary"; done
mcqs_configure_kubeconfig
helm -n "$NAMESPACE" status "$RELEASE" --show-desc=false
printf '\nPods:\n'
kubectl -n "$NAMESPACE" get pods -o wide
