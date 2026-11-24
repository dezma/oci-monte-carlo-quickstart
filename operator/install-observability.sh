#!/usr/bin/env bash
set -euo pipefail

# Installs a private, optional Kubernetes observability stack. It is kept out
# of the default runtime so a benchmark baseline stays small and explicit.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

NAMESPACE="mcqs-observability"
RELEASE="mcqs-observability"
RETENTION="7d"
CHART_VERSION=""

usage() {
  printf '%s\n' "Usage: $0 [--namespace name] [--release name] [--retention duration] [--chart-version version]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --retention) RETENTION="${2:-}"; shift 2 ;;
    --chart-version) CHART_VERSION="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "namespace must be a valid Kubernetes namespace."
[[ "$RELEASE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || mcqs_fail "release must be a valid Helm release name."
[[ "$RETENTION" =~ ^[1-9][0-9]*(h|d|w|y)$ ]] || mcqs_fail "retention must be a positive Prometheus duration, such as 24h or 7d."

mcqs_require_operator_environment
for binary in helm kubectl; do mcqs_require_command "$binary"; done
mcqs_configure_kubeconfig

mcqs_note "Installing private observability"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

chart_arguments=()
[[ -z "$CHART_VERSION" ]] || chart_arguments+=(--version "$CHART_VERSION")

helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  "${chart_arguments[@]}" \
  --set grafana.enabled=true \
  --set grafana.service.type=ClusterIP \
  --set grafana.persistence.enabled=false \
  --set alertmanager.enabled=false \
  --set kube-state-metrics.enabled=true \
  --set prometheus-node-exporter.enabled=true \
  --set prometheus.prometheusSpec.retention="$RETENTION" \
  --set prometheus.prometheusSpec.resources.requests.cpu=250m \
  --set prometheus.prometheusSpec.resources.requests.memory=1Gi \
  --set prometheus.prometheusSpec.resources.limits.cpu=1 \
  --set prometheus.prometheusSpec.resources.limits.memory=2Gi \
  --wait --timeout 15m

printf 'Observability is ready. View status with:\n'
printf '  ./operator/observability-status.sh --namespace %s --release %s\n' "$NAMESPACE" "$RELEASE"
printf 'Open Grafana privately with:\n'
printf '  ./operator/open-grafana.sh --namespace %s --release %s\n' "$NAMESPACE" "$RELEASE"
