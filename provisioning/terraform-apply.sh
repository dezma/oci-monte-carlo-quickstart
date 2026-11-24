#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

AUTO_APPROVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      AUTO_APPROVE=true
      shift
      ;;
    --help|-h)
      printf 'Usage: %s [--yes]\n\nApplies the Terraform configuration from a local OCI CLI environment. OCI Resource Manager is the recommended infrastructure path.\n' "$0"
      exit 0
      ;;
    *)
      mcqs_fail "Unknown option: $1"
      ;;
  esac
done

mcqs_require_command terraform
[[ -f "${MCQS_TERRAFORM_DIR}/terraform.tfvars" ]] || mcqs_fail "Create terraform/terraform.tfvars from terraform.tfvars.example first."
mcqs_note "Initializing and validating Terraform"
terraform -chdir="${MCQS_TERRAFORM_DIR}" init
terraform -chdir="${MCQS_TERRAFORM_DIR}" fmt -check -recursive
terraform -chdir="${MCQS_TERRAFORM_DIR}" validate
MCQS_PLAN_FILE="${MCQS_ROOT_DIR}/.mcqs-quickstart.tfplan"
terraform -chdir="${MCQS_TERRAFORM_DIR}" plan -out="$MCQS_PLAN_FILE"
if [[ "$AUTO_APPROVE" != true ]]; then
  mcqs_confirm "Apply this reviewed plan?"
fi
terraform -chdir="${MCQS_TERRAFORM_DIR}" apply "$MCQS_PLAN_FILE"
rm -f "$MCQS_PLAN_FILE"
mcqs_note "Infrastructure ready"
terraform -chdir="${MCQS_TERRAFORM_DIR}" output
printf '\nNext: create an OCI Bastion Managed SSH session to the operator instance, then run the commands in operator/ from that host.\n'
