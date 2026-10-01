#!/usr/bin/env bash
# Shared helpers for the provisioning and private-operator workflows.

set -o pipefail
umask 077

MCQS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MCQS_ROOT_DIR="$(cd -- "${MCQS_LIB_DIR}/.." && pwd -P)"
MCQS_OPERATOR_DIR="${MCQS_ROOT_DIR}/operator"
MCQS_PROVISIONING_DIR="${MCQS_ROOT_DIR}/provisioning"
MCQS_TERRAFORM_DIR="${MCQS_ROOT_DIR}/terraform"
MCQS_HELM_DIR="${MCQS_ROOT_DIR}/helm/monte-carlo"
MCQS_NAMESPACE="${MCQS_NAMESPACE:-monte-carlo}"
MCQS_SERVICE_ACCOUNT="${MCQS_SERVICE_ACCOUNT:-monte-carlo-runner}"
export KUBECONFIG="${KUBECONFIG:-${MCQS_ROOT_DIR}/.kube/config}"

mcqs_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

mcqs_note() {
  printf '\n==> %s\n' "$*"
}

mcqs_require_command() {
  command -v "$1" >/dev/null 2>&1 || mcqs_fail "Required command not found: $1"
}

mcqs_require_value() {
  local value_name="$1"
  [[ -n "${!value_name:-}" ]] || mcqs_fail "Set ${value_name} before running this command."
}

mcqs_require_operator_environment() {
  [[ "${OCI_CLI_AUTH:-}" == "instance_principal" ]] || \
    mcqs_fail "This command must run on the provisioned private operator instance. Connect through OCI Bastion and source /etc/profile.d/mcqs-runtime.sh."
  [[ -f /home/opc/.mcqs-operator-ready ]] || \
    mcqs_fail "The operator bootstrap is incomplete. Run operator/doctor.sh after reviewing /var/log/mcqs-operator-bootstrap.log."
}

mcqs_confirm() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} Type YES to continue: " answer
  [[ "$answer" == "YES" ]] || mcqs_fail "No change was made."
}

mcqs_tf_output() {
  mcqs_require_command terraform
  local output_name="$1"
  terraform -chdir="${MCQS_TERRAFORM_DIR}" output -raw "$output_name"
}

mcqs_validate_image_metadata() {
  [[ "${MCQS_IMAGE_REPOSITORY:-}" =~ ^[[:alnum:]][[:alnum:]./_-]*$ ]] || \
    mcqs_fail "MCQS_IMAGE_REPOSITORY is invalid. Run operator/build-and-push.sh."
  [[ "${MCQS_IMAGE_DIGEST:-}" =~ ^sha256:[a-f0-9]{64}$ ]] || \
    mcqs_fail "MCQS_IMAGE_DIGEST is missing or invalid. Run operator/build-and-push.sh; do not deploy a mutable image tag."
}

mcqs_load_image_metadata() {
  local metadata_file="${MCQS_ROOT_DIR}/.mcqs-image.env"
  if [[ -f "$metadata_file" ]]; then
    # Read only the two literal fields we create. Do not source a local file as
    # shell code, and fail explicitly instead of silently deploying an empty
    # digest after a failed image push.
    local saved_repository saved_digest
    saved_repository="$(awk -F= '$1 == "MCQS_IMAGE_REPOSITORY" { print substr($0, index($0, "=") + 1); exit }' "$metadata_file")"
    saved_digest="$(awk -F= '$1 == "MCQS_IMAGE_DIGEST" { print substr($0, index($0, "=") + 1); exit }' "$metadata_file")"
    MCQS_IMAGE_REPOSITORY="${MCQS_IMAGE_REPOSITORY:-$saved_repository}"
    MCQS_IMAGE_DIGEST="${MCQS_IMAGE_DIGEST:-$saved_digest}"
    export MCQS_IMAGE_REPOSITORY MCQS_IMAGE_DIGEST
  fi

  # The operator profile deliberately supplies a repository before the first
  # image is built. A digest is only expected after build-and-push completes.
  if [[ -n "${MCQS_IMAGE_REPOSITORY:-}" || -n "${MCQS_IMAGE_DIGEST:-}" ]]; then
    mcqs_validate_image_metadata
  fi
}

mcqs_write_image_metadata() {
  mcqs_validate_image_metadata
  umask 077
  printf 'MCQS_IMAGE_REPOSITORY=%s\nMCQS_IMAGE_DIGEST=%s\n' \
    "$MCQS_IMAGE_REPOSITORY" "$MCQS_IMAGE_DIGEST" > "${MCQS_ROOT_DIR}/.mcqs-image.env"
}

mcqs_configure_kubeconfig() {
  mcqs_require_operator_environment
  local cluster_id="${CLUSTER_ID:-${MCQS_CLUSTER_ID:-}}"
  local region="${REGION:-${MCQS_REGION:-}}"
  mcqs_require_command oci
  mcqs_require_command kubectl
  # The runtime bundle intentionally excludes Terraform state. The generated
  # operator profile normally supplies both values. The local Terraform
  # fallback is retained only for a developer running against local state.
  if [[ -z "$cluster_id" && -d "${MCQS_TERRAFORM_DIR}" ]] && command -v terraform >/dev/null 2>&1; then
    cluster_id="$(mcqs_tf_output cluster_id)"
  fi
  if [[ -z "$region" && -d "${MCQS_TERRAFORM_DIR}" ]] && command -v terraform >/dev/null 2>&1; then
    region="$(mcqs_tf_output region)"
  fi
  [[ -n "$cluster_id" ]] || mcqs_fail "CLUSTER_ID is not configured. Source /etc/profile.d/mcqs-runtime.sh on the provisioned operator instance."
  [[ -n "$region" ]] || mcqs_fail "REGION is not configured. Source /etc/profile.d/mcqs-runtime.sh on the provisioned operator instance."
  mkdir -p "$(dirname "$KUBECONFIG")"
  mcqs_note "Generating a kubeconfig for the private OKE endpoint"
  local auth_args=()
  if [[ "${OCI_CLI_AUTH:-}" == "instance_principal" ]]; then
    auth_args=(--auth instance_principal --with-auth-context)
  fi
  oci ce cluster create-kubeconfig \
    --cluster-id "$cluster_id" \
    --file "$KUBECONFIG" \
    --region "$region" \
    --token-version 2.0.0 \
    --kube-endpoint PRIVATE_ENDPOINT \
    "${auth_args[@]}" >/dev/null
  kubectl cluster-info >/dev/null || mcqs_fail "Cannot reach the private OKE API. Run this command from the provisioned operator instance after connecting through OCI Bastion."
}

mcqs_ocir_login_username() {
  local tenancy_namespace="$1"
  mcqs_require_value OCI_USER_NAME
  [[ "$OCI_USER_NAME" != "${tenancy_namespace}/"* ]] || \
    mcqs_fail "Set OCI_USER_NAME to <username> or <identity-domain>/<username>, without the tenancy namespace."
  printf '%s/%s\n' "$tenancy_namespace" "$OCI_USER_NAME"
}
