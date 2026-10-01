#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

MCQS_BUILD_MODE="native"
MCQS_NATIVE_ARCHITECTURE="${MCQS_NODE_ARCHITECTURE:-amd64}"
case "${1:-}" in
  --help|-h)
    printf 'Usage: %s [--architecture amd64|arm64 | --multi-arch]\n\nBuilds and publishes an immutable image to the Terraform-created private OCIR repository. By default it publishes the architecture selected for the OKE node pool, using the normal Docker push path. Use --multi-arch only when an amd64+arm64 manifest is needed and the Buildx builder can authenticate to OCIR. Set OCI_USER_NAME first.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  --architecture)
    [[ $# == 2 ]] || mcqs_fail "--architecture requires amd64 or arm64."
    MCQS_NATIVE_ARCHITECTURE="$2"
    [[ "$MCQS_NATIVE_ARCHITECTURE" == amd64 || "$MCQS_NATIVE_ARCHITECTURE" == arm64 ]] || \
      mcqs_fail "--architecture must be amd64 or arm64."
    ;;
  --multi-arch)
    [[ $# == 1 ]] || mcqs_fail "--multi-arch does not accept another argument."
    MCQS_BUILD_MODE="multi-arch"
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_require_command docker
mcqs_require_command oci
mcqs_require_command jq
mcqs_require_operator_environment

case "$(uname -m)" in
  x86_64|amd64) MCQS_OPERATOR_ARCHITECTURE="amd64" ;;
  aarch64|arm64) MCQS_OPERATOR_ARCHITECTURE="arm64" ;;
  *) mcqs_fail "Unsupported operator CPU architecture: $(uname -m)" ;;
esac
if [[ "$MCQS_BUILD_MODE" == "native" && -n "${MCQS_NODE_ARCHITECTURE:-}" && "$MCQS_NATIVE_ARCHITECTURE" != "$MCQS_NODE_ARCHITECTURE" ]]; then
  mcqs_fail "--architecture ${MCQS_NATIVE_ARCHITECTURE} does not match this quickstart node pool (${MCQS_NODE_ARCHITECTURE}). Use the matching architecture or --multi-arch."
fi
if [[ "$MCQS_BUILD_MODE" == "native" && "$MCQS_OPERATOR_ARCHITECTURE" != "$MCQS_NATIVE_ARCHITECTURE" ]]; then
  mcqs_fail "A native ${MCQS_NATIVE_ARCHITECTURE} build needs a matching operator VM, but this host is ${MCQS_OPERATOR_ARCHITECTURE}. Use the architecture-matching default operator shape or an explicitly prepared multi-architecture builder."
fi

if [[ "$MCQS_BUILD_MODE" == "multi-arch" ]]; then
  docker buildx version >/dev/null 2>&1 || mcqs_fail "Docker buildx is required to publish the amd64/arm64 image manifest."
  MCQS_BUILDER_NAME="${MCQS_BUILDER_NAME:-mcqs-multiarch}"
  if ! docker buildx inspect "$MCQS_BUILDER_NAME" >/dev/null 2>&1; then
    mcqs_note "Creating a persistent Buildx builder for amd64 and arm64 images"
    docker buildx create --name "$MCQS_BUILDER_NAME" --driver docker-container --use >/dev/null
  else
    docker buildx use "$MCQS_BUILDER_NAME"
  fi
  docker buildx inspect --bootstrap >/dev/null
fi

MCQS_IMAGE_REPOSITORY="${MCQS_IMAGE_REPOSITORY:-}"
if [[ -z "$MCQS_IMAGE_REPOSITORY" && -d "${MCQS_TERRAFORM_DIR}" ]] && command -v terraform >/dev/null 2>&1; then
  MCQS_IMAGE_REPOSITORY="$(mcqs_tf_output container_repository_url)"
fi
[[ -n "$MCQS_IMAGE_REPOSITORY" ]] || mcqs_fail "MCQS_IMAGE_REPOSITORY is not configured. Source /etc/profile.d/mcqs-runtime.sh on the provisioned operator instance."
MCQS_IMAGE_REPOSITORY="${MCQS_IMAGE_REPOSITORY#https://}"
MCQS_OCIR_REGISTRY="${MCQS_IMAGE_REPOSITORY%%/*}"
MCQS_IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"
MCQS_IMAGE_REFERENCE="${MCQS_IMAGE_REPOSITORY}:${MCQS_IMAGE_TAG}"
MCQS_BUILD_METADATA="$(mktemp)"

mcqs_require_value OCI_USER_NAME
MCQS_TENANCY_NAMESPACE="${OCI_TENANCY_NAMESPACE:-$(oci os ns get --query data --raw-output)}"
MCQS_OCIR_LOGIN_USER="$(mcqs_ocir_login_username "$MCQS_TENANCY_NAMESPACE")"

trap 'docker logout "$MCQS_OCIR_REGISTRY" >/dev/null 2>&1 || true; rm -f "$MCQS_BUILD_METADATA"' EXIT
mcqs_note "Authenticating to private OCIR"
printf "Enter the OCIR auth token at Docker's hidden Password prompt. Do not quote, export, or paste it into a shell command.\n"
if ! docker login "$MCQS_OCIR_REGISTRY" --username "$MCQS_OCIR_LOGIN_USER"; then
  mcqs_fail "OCIR login failed. OCI_USER_NAME must be <username> or <identity-domain>/<username>; verify that the auth token belongs to that same user."
fi

if [[ "$MCQS_BUILD_MODE" == "native" ]]; then
  mcqs_note "Building and publishing an immutable linux/${MCQS_NATIVE_ARCHITECTURE} image"
  docker build \
    --platform "linux/${MCQS_NATIVE_ARCHITECTURE}" \
    --pull \
    --tag "$MCQS_IMAGE_REFERENCE" \
    "$MCQS_ROOT_DIR"
  docker push "$MCQS_IMAGE_REFERENCE"
  MCQS_REPO_DIGEST="$(docker image inspect "$MCQS_IMAGE_REFERENCE" --format '{{index .RepoDigests 0}}')"
  [[ "$MCQS_REPO_DIGEST" == "${MCQS_IMAGE_REPOSITORY}@sha256:"* ]] || \
    mcqs_fail "OCIR push completed but Docker did not return an immutable repository digest. Do not deploy this image."
  MCQS_IMAGE_DIGEST="${MCQS_REPO_DIGEST##*@}"
else
  mcqs_note "Building and publishing an immutable linux/amd64 + linux/arm64 manifest"
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --pull \
    --provenance=true \
    --sbom=true \
    --metadata-file "$MCQS_BUILD_METADATA" \
    --tag "$MCQS_IMAGE_REFERENCE" \
    --push \
    "$MCQS_ROOT_DIR"

  MCQS_IMAGE_DIGEST="$(jq -r '."containerimage.digest" // ."containerimage.descriptor".digest // empty' "$MCQS_BUILD_METADATA")"
  if [[ "$MCQS_IMAGE_DIGEST" != sha256:* ]]; then
    # Older Buildx releases can omit containerimage.digest. The registry-backed
    # descriptor is an equivalent fallback and is deliberately rendered as JSON:
    # `.Manifest` itself is a display object, not a struct with a Digest field.
    MCQS_IMAGE_DIGEST="$(docker buildx imagetools inspect "$MCQS_IMAGE_REFERENCE" \
      --format '{{json .Manifest}}' | jq -r '.digest // empty' || true)"
  fi
fi
[[ "$MCQS_IMAGE_DIGEST" == sha256:* ]] || mcqs_fail "Could not resolve an immutable manifest digest."

mcqs_write_image_metadata

mcqs_note "Image published"
printf 'Repository: %s\nDigest:     %s\n' "$MCQS_IMAGE_REPOSITORY" "$MCQS_IMAGE_DIGEST"
printf 'Image metadata was saved locally without credentials. The temporary Docker login is removed when this command exits. Configure OCI Registry scanning and signing before production use.\n'
