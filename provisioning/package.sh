#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nCreates dist/oci-monte-carlo-quickstart.zip without local credentials, state, images, or validation tooling.\n' "$0"
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
MCQS_ARCHIVE="${MCQS_DIST_DIR}/oci-monte-carlo-quickstart.zip"
MCQS_PARENT_DIR="$(dirname "$MCQS_ROOT_DIR")"
MCQS_BASENAME="$(basename "$MCQS_ROOT_DIR")"
mkdir -p "$MCQS_DIST_DIR"
rm -f "$MCQS_ARCHIVE"

mcqs_note "Packaging the deployable quickstart"
(
  cd "$MCQS_PARENT_DIR"
  zip -qr "$MCQS_ARCHIVE" "$MCQS_BASENAME" \
    -x "${MCQS_BASENAME}/.git/*" \
       "${MCQS_BASENAME}/.venv/*" \
       "${MCQS_BASENAME}/.tools/*" \
       "${MCQS_BASENAME}/.provider-source/*" \
       "${MCQS_BASENAME}/.mcqs-provider-schema.json" \
       "${MCQS_BASENAME}/.validation-venv/*" \
       "${MCQS_BASENAME}/.tmp-validation/*" \
       "${MCQS_BASENAME}/.pytest_cache/*" \
       "${MCQS_BASENAME}/pytest-of-root/*" \
       "${MCQS_BASENAME}/.ruff_cache/*" \
       "${MCQS_BASENAME}/*/__pycache__/*" \
       "${MCQS_BASENAME}/*.pyc" \
       "${MCQS_BASENAME}/.terraform/*" \
       "${MCQS_BASENAME}/terraform/.terraform/*" \
       "${MCQS_BASENAME}/terraform/terraform.tfstate*" \
       "${MCQS_BASENAME}/terraform/terraform.tfvars" \
       "${MCQS_BASENAME}/.kube/*" \
       "${MCQS_BASENAME}/.mcqs-*" \
       "${MCQS_BASENAME}/dist/*"
)
printf 'Created %s\n' "$MCQS_ARCHIVE"
