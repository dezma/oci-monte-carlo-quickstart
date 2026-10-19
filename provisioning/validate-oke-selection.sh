#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

COMPARTMENT_ID=""
NODE_SHAPE=""
ARCHITECTURE=""
KUBERNETES_VERSION=""
NODE_IMAGE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compartment-id)
      COMPARTMENT_ID="${2:-}"
      shift 2
      ;;
    --node-shape)
      NODE_SHAPE="${2:-}"
      shift 2
      ;;
    --architecture)
      ARCHITECTURE="${2:-}"
      shift 2
      ;;
    --kubernetes-version)
      KUBERNETES_VERSION="${2:-}"
      shift 2
      ;;
    --node-image-id)
      NODE_IMAGE_ID="${2:-}"
      shift 2
      ;;
    --help|-h)
      printf 'Usage: %s --compartment-id <ocid> --node-shape <shape> --architecture amd64|arm64 --kubernetes-version <full-version> --node-image-id <image-ocid>\n\nValidates the selected full OKE patch version and Oracle Linux 8 node image against live OCI control-plane options before Resource Manager provisioning.\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

[[ -n "$COMPARTMENT_ID" ]] || mcqs_fail "--compartment-id is required."
[[ -n "$NODE_SHAPE" ]] || mcqs_fail "--node-shape is required."
[[ -n "$ARCHITECTURE" ]] || mcqs_fail "--architecture is required."
[[ -n "$KUBERNETES_VERSION" ]] || mcqs_fail "--kubernetes-version is required."
[[ "$KUBERNETES_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  mcqs_fail "--kubernetes-version must be a full OKE patch version, for example v1.36.1."
[[ -n "$NODE_IMAGE_ID" ]] || mcqs_fail "--node-image-id is required."
[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || \
  mcqs_fail "--architecture must be amd64 or arm64."
[[ "$NODE_IMAGE_ID" == ocid1.image.* ]] || mcqs_fail "--node-image-id must be an OCI image OCID."
mcqs_require_command oci
mcqs_require_command jq

case "$ARCHITECTURE" in
  amd64) NODE_POOL_ARCH="X86_64" ;;
  arm64) NODE_POOL_ARCH="AARCH64" ;;
esac

mcqs_note "Checking ${KUBERNETES_VERSION} against live OKE cluster options"
CLUSTER_OPTIONS="$(oci ce cluster-option get \
  --cluster-option-id all \
  --compartment-id "$COMPARTMENT_ID" \
  --output json)"
if ! jq -e --arg requested "$KUBERNETES_VERSION" '
  .data["kubernetes-versions"][]? |
  select(. == $requested)
' >/dev/null <<<"$CLUSTER_OPTIONS"; then
  mcqs_fail "${KUBERNETES_VERSION} is not currently offered in this compartment/region. Run provisioning/list-oke-options.sh and choose a live version."
fi

mcqs_note "Checking the ${ARCHITECTURE} Oracle Linux 8 node image"
NODE_OPTIONS="$(oci ce node-pool-options get \
  --node-pool-option-id all \
  --compartment-id "$COMPARTMENT_ID" \
  --node-pool-k8s-version "$KUBERNETES_VERSION" \
  --node-pool-os-arch "$NODE_POOL_ARCH" \
  --node-pool-os-type OL8 \
  --should-list-all-patch-versions false \
  --output json)"
if ! jq -e --arg image "$NODE_IMAGE_ID" '
  .data.sources[]? | select(."image-id" == $image)
' >/dev/null <<<"$NODE_OPTIONS"; then
  mcqs_fail "The supplied node image is not an OL8 ${ARCHITECTURE} image offered for ${KUBERNETES_VERSION}. Rerun provisioning/list-oke-options.sh with the same version and architecture."
fi

cat <<MESSAGE
Live OKE selection validated. Use these Resource Manager inputs:

  kubernetes_version = "${KUBERNETES_VERSION}"
  node_shape         = "${NODE_SHAPE}"
  node_architecture  = "${ARCHITECTURE}"
  node_image_id      = "${NODE_IMAGE_ID}"

Shape capacity remains availability-domain specific. Verify it separately with
provisioning/list-shapes.sh before applying the stack.
MESSAGE
