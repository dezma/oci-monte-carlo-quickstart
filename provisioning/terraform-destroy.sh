#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      printf 'Usage: %s\n\nDestroys Terraform-managed infrastructure from a local OCI CLI environment. For a Resource Manager stack, use a Resource Manager Destroy job instead.\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

mcqs_require_command terraform
[[ -f "${MCQS_TERRAFORM_DIR}/terraform.tfvars" ]] || mcqs_fail "terraform/terraform.tfvars is required."
mcqs_note "Creating a destruction plan"
MCQS_DESTROY_PLAN="${MCQS_ROOT_DIR}/.mcqs-destroy.tfplan"
terraform -chdir="$MCQS_TERRAFORM_DIR" plan -destroy -out="$MCQS_DESTROY_PLAN"
read -r -p "This releases the Terraform-managed OCI resources. Type DESTROY to continue: " MCQS_DESTROY_CONFIRMATION
[[ "$MCQS_DESTROY_CONFIRMATION" == "DESTROY" ]] || mcqs_fail "No infrastructure was deleted."
terraform -chdir="$MCQS_TERRAFORM_DIR" apply "$MCQS_DESTROY_PLAN"
rm -f "$MCQS_DESTROY_PLAN"
