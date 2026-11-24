#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nCreates or rotates the OCIR pull secret in the Monte Carlo namespace. Set OCI_USER_NAME first.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_require_command docker
mcqs_require_command oci
mcqs_require_command kubectl
mcqs_require_operator_environment
mcqs_require_value OCI_USER_NAME
mcqs_configure_kubeconfig

MCQS_IMAGE_REPOSITORY="${MCQS_IMAGE_REPOSITORY:-}"
if [[ -z "$MCQS_IMAGE_REPOSITORY" && -d "${MCQS_TERRAFORM_DIR}" ]] && command -v terraform >/dev/null 2>&1; then
  MCQS_IMAGE_REPOSITORY="$(mcqs_tf_output container_repository_url)"
fi
[[ -n "$MCQS_IMAGE_REPOSITORY" ]] || mcqs_fail "MCQS_IMAGE_REPOSITORY is not configured. Source /etc/profile.d/mcqs-runtime.sh on the provisioned operator instance."
MCQS_IMAGE_REPOSITORY="${MCQS_IMAGE_REPOSITORY#https://}"
MCQS_OCIR_REGISTRY="${MCQS_IMAGE_REPOSITORY%%/*}"
MCQS_TENANCY_NAMESPACE="${OCI_TENANCY_NAMESPACE:-$(oci os ns get --query data --raw-output)}"
MCQS_OCIR_LOGIN_USER="$(mcqs_ocir_login_username "$MCQS_TENANCY_NAMESPACE")"
MCQS_DOCKER_DIR="$(mktemp -d /tmp/mcqs-ocir.XXXXXX)"
trap 'docker --config "$MCQS_DOCKER_DIR" logout "$MCQS_OCIR_REGISTRY" >/dev/null 2>&1 || true; rm -rf -- "$MCQS_DOCKER_DIR"' EXIT

mcqs_note "Authenticating to private OCIR for the Kubernetes pull secret"
printf "Enter the OCIR auth token at Docker's hidden Password prompt. Do not quote, export, or paste it into a shell command.\n"
if ! docker --config "$MCQS_DOCKER_DIR" login "$MCQS_OCIR_REGISTRY" --username "$MCQS_OCIR_LOGIN_USER"; then
  mcqs_fail "OCIR login failed. OCI_USER_NAME must be <username> or <identity-domain>/<username>; verify that the auth token belongs to that same user."
fi

mcqs_note "Creating or rotating the private OCIR pull secret"
kubectl -n "$MCQS_NAMESPACE" create secret generic ocir-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="${MCQS_DOCKER_DIR}/config.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

printf 'OCIR pull secret is ready in namespace %s. Rotate it before the token expires.\n' "$MCQS_NAMESPACE"
