#!/usr/bin/env bash
set -euo pipefail

# Applies the Terraform-defined NoSchedule taint to currently joined dedicated
# benchmark nodes. This is deliberately run before each profile benchmark and
# can be run again after a node replacement or scale-out.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

PROFILE_ID=""
WAIT_SECONDS=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE_ID="${2:-}"
      shift 2
      ;;
    --wait-seconds)
      WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --help|-h)
      printf 'Usage: %s --profile profile-id [--wait-seconds seconds]\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

[[ "$PROFILE_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  mcqs_fail "profile must contain lowercase letters, digits, and hyphens."
[[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || mcqs_fail "wait-seconds must be a positive integer."

mcqs_require_operator_environment
mcqs_require_command jq
mcqs_require_command kubectl
mcqs_configure_kubeconfig

CONFIG_FILE="${MCQS_BENCHMARK_POOL_CONFIG:-/etc/mcqs-benchmark-pools.json}"
[[ -r "$CONFIG_FILE" ]] || mcqs_fail "No Terraform benchmark-profile configuration is readable at ${CONFIG_FILE}. Select a benchmark profile during provisioning and refresh the operator configuration, or use --node-selector directly."

jq -e --arg profile "$PROFILE_ID" '.[$profile] | objects' "$CONFIG_FILE" >/dev/null || \
  mcqs_fail "Benchmark profile ${PROFILE_ID} is not defined in ${CONFIG_FILE}."

SELECTOR_KEY="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].selector.key' "$CONFIG_FILE")"
SELECTOR_VALUE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].selector.value' "$CONFIG_FILE")"
TAINT_KEY="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.key' "$CONFIG_FILE")"
TAINT_VALUE="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.value' "$CONFIG_FILE")"
TAINT_EFFECT="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].taint.effect' "$CONFIG_FILE")"
EXPECTED_NODES="$(jq -r --arg profile "$PROFILE_ID" '.[$profile].initial_size' "$CONFIG_FILE")"

[[ "$SELECTOR_KEY" != "null" && "$SELECTOR_VALUE" != "null" && "$TAINT_KEY" != "null" && "$TAINT_VALUE" != "null" && "$TAINT_EFFECT" == "NoSchedule" ]] || \
  mcqs_fail "Benchmark profile ${PROFILE_ID} has an incomplete selector or taint definition."

deadline=$(( $(date +%s) + WAIT_SECONDS ))
while true; do
  mapfile -t NODES < <(kubectl get nodes -l "${SELECTOR_KEY}=${SELECTOR_VALUE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if (( ${#NODES[@]} >= EXPECTED_NODES )); then
    break
  fi
  if (( $(date +%s) >= deadline )); then
    mcqs_fail "Timed out waiting for ${EXPECTED_NODES} node(s) labelled ${SELECTOR_KEY}=${SELECTOR_VALUE}; found ${#NODES[@]}. Check OKE node-pool capacity and events."
  fi
  sleep 10
done

mcqs_note "Applying benchmark taint ${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT} to ${#NODES[@]} node(s)"
# OCI VCN-native OKE commonly registers nodes with IP-address-style names such
# as 10.42.1.128. `kubectl taint node <name>` can parse those dotted names as
# a resource expression on some kubectl releases. Target the profile label in
# one operation instead; it is both unambiguous and ensures every current or
# replacement node in the dedicated pool receives the same taint.
kubectl taint node \
  --selector "${SELECTOR_KEY}=${SELECTOR_VALUE}" \
  "${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}" \
  --overwrite >/dev/null

kubectl get nodes -l "${SELECTOR_KEY}=${SELECTOR_VALUE}" -L "$SELECTOR_KEY"
