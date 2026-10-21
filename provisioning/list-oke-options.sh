#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

COMPARTMENT_ID=""
NODE_SHAPE=""
KUBERNETES_VERSION=""
ARCHITECTURE=""

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
    --kubernetes-version)
      KUBERNETES_VERSION="${2:-}"
      shift 2
      ;;
    --architecture)
      ARCHITECTURE="${2:-}"
      shift 2
      ;;
    --help|-h)
      printf 'Usage: %s --compartment-id <ocid> [--node-shape <shape> --architecture amd64|arm64 --kubernetes-version <version>]\n\nWithout a version, lists supported OKE versions. With a shape, architecture, and version, lists compatible Oracle Linux 8 node image OCIDs.\n' "$0"
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

if [[ -z "$KUBERNETES_VERSION" ]]; then
  [[ -z "$NODE_SHAPE" && -z "$ARCHITECTURE" ]] || mcqs_fail "--node-shape and --architecture require --kubernetes-version."
  mcqs_note "Supported Kubernetes versions"
  oci ce cluster-options get \
    --cluster-option-id all \
    --compartment-id "$COMPARTMENT_ID" \
    --query 'data."kubernetes-versions"' \
    --output table
  cat <<'MESSAGE'

Select one full version from this live response, then rerun with --node-shape,
--architecture, and --kubernetes-version to obtain a compatible node image OCID.
Minor-only values such as `v1.36` are not valid OKE API inputs. Kubernetes
version and node image are required Resource Manager inputs.
MESSAGE
  exit 0
fi

[[ -n "$NODE_SHAPE" ]] || mcqs_fail "--node-shape is required when --kubernetes-version is set."
[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || \
  mcqs_fail "--architecture must be amd64 or arm64 when --kubernetes-version is set."

case "$ARCHITECTURE" in
  amd64) NODE_ARCH="X86_64" ;;
  arm64) NODE_ARCH="AARCH64" ;;
esac

mcqs_note "Compatible Oracle Linux 8 images for ${NODE_SHAPE} (${NODE_ARCH}) and ${KUBERNETES_VERSION}"
oci ce node-pool-options get \
  --node-pool-option-id all \
  --compartment-id "$COMPARTMENT_ID" \
  --node-pool-k8s-version "$KUBERNETES_VERSION" \
  --node-pool-os-arch "$NODE_ARCH" \
  --node-pool-os-type OL8 \
  --should-list-all-patch-versions false \
  --query 'data.sources[].{"image_id":"image-id","source_name":"source-name"}' \
  --output table

cat <<'MESSAGE'

Copy one image_id into Resource Manager's node_image_id field and enter the
same architecture in node_architecture. The selected image must come from this
exact output; do not infer architecture from a shape family or reuse an image
OCID from another Kubernetes version or architecture.
MESSAGE
