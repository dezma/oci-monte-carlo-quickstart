#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

COMPARTMENT_ID=""
AVAILABILITY_DOMAIN=""
FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compartment-id)
      COMPARTMENT_ID="${2:-}"
      shift 2
      ;;
    --availability-domain)
      AVAILABILITY_DOMAIN="${2:-}"
      shift 2
      ;;
    --filter)
      FILTER="${2:-}"
      shift 2
      ;;
    --help|-h)
      printf 'Usage: %s --compartment-id <ocid> [--availability-domain <name>] [--filter <text>]\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

[[ -n "$COMPARTMENT_ID" ]] || mcqs_fail "--compartment-id is required."
mcqs_require_command oci
mcqs_require_command jq

if [[ -z "$AVAILABILITY_DOMAIN" ]]; then
  AVAILABILITY_DOMAIN="$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" --query 'data[0].name' --raw-output)"
fi

mcqs_note "Shapes reported by OCI for ${AVAILABILITY_DOMAIN}"
SHAPES_JSON="$(oci compute shape list --compartment-id "$COMPARTMENT_ID" --availability-domain "$AVAILABILITY_DOMAIN" --all --output json)"

if [[ -n "$FILTER" ]]; then
  jq --arg filter "$FILTER" '
    .data
    | map(select((.shape + " " + (."processor-description" // "")) | test($filter; "i")))
    | sort_by(.shape)
    | .[]
    | {shape, processor: ."processor-description", ocpus, memory_gbs: ."memory-in-gbs", gpus, network_gbps: ."networking-bandwidth-in-gbps"}
  ' <<<"$SHAPES_JSON"
else
  jq '
    .data
    | sort_by(.shape)
    | .[]
    | {shape, processor: ."processor-description", ocpus, memory_gbs: ."memory-in-gbs", gpus, network_gbps: ."networking-bandwidth-in-gbps"}
  ' <<<"$SHAPES_JSON"
fi

cat <<'MESSAGE'

The output is the live availability source of truth. Select an OKE-supported node shape and
confirm capacity before applying Terraform. Flexible shapes need OCPU and memory values;
fixed bare-metal/HPC/GPU shapes must use null node_shape_ocpus and node_shape_memory_gbs.

Useful filters:
  --filter 'E6|E6.Ax'       AMD standard and Acceleron candidates
  --filter 'Standard4|X12'  Intel Acceleron candidates
  --filter 'A1|A2|A4'       Ampere Altra, AmpereOne, and Acceleron candidates
MESSAGE
