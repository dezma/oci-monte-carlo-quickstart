#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

NAMESPACE="mcqs-observability"
RELEASE="mcqs-observability"
LOCAL_PORT="3000"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
    --help|-h)
      printf '%s\n' "Usage: $0 [--namespace name] [--release name] [--local-port 3000]"
      exit 0
      ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$LOCAL_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || mcqs_fail "local-port must be a TCP port number."
mcqs_require_operator_environment
for binary in kubectl base64; do mcqs_require_command "$binary"; done
mcqs_configure_kubeconfig

secret_name="${RELEASE}-grafana"
password="$(kubectl -n "$NAMESPACE" get secret "$secret_name" -o jsonpath='{.data.admin-password}' | base64 --decode)"
printf 'Grafana user:     admin\nGrafana password: %s\n' "$password"
printf 'Grafana URL:      http://127.0.0.1:%s\n' "$LOCAL_PORT"
printf 'Keep this terminal open while using the private port-forward.\n\n'
exec kubectl -n "$NAMESPACE" port-forward "service/${RELEASE}-grafana" "${LOCAL_PORT}:80"
