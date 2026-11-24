#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nCreates dist/orm.zip for OCI Resource Manager, excluding state and local variables.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_require_command zip
"${MCQS_PROVISIONING_DIR}/build-runtime-bundle.sh"
MCQS_DIST_DIR="${MCQS_ROOT_DIR}/dist"
MCQS_ORM_ARCHIVE="${MCQS_DIST_DIR}/orm.zip"
mkdir -p "$MCQS_DIST_DIR"
rm -f "$MCQS_ORM_ARCHIVE"

mcqs_note "Packaging Terraform for OCI Resource Manager"
(
  cd "$MCQS_TERRAFORM_DIR"
  zip -qr "$MCQS_ORM_ARCHIVE" . \
    -x 'terraform.tfvars' 'terraform.tfstate*' '.terraform/*'
)
printf 'Created %s\n' "$MCQS_ORM_ARCHIVE"
