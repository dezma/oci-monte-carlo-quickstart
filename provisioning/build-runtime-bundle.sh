#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nBuilds the credential-free runtime bundle that Resource Manager installs on the private operator instance.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_require_command tar
MCQS_OPERATOR_DIR="${MCQS_TERRAFORM_DIR}/operator/payload"
MCQS_OPERATOR_BUNDLE="${MCQS_OPERATOR_DIR}/monte-carlo-quickstart.tar.gz"
MCQS_PARENT_DIR="$(dirname "$MCQS_ROOT_DIR")"
MCQS_BASENAME="$(basename "$MCQS_ROOT_DIR")"

mkdir -p "$MCQS_OPERATOR_DIR"
rm -f "$MCQS_OPERATOR_BUNDLE"

mcqs_note "Building the private operator runtime bundle"
# The operator has no Terraform binary or state and must not receive local
# provisioning tools, credentials, test tooling, or build artefacts.  Keep the
# payload explicit so a new repository file is not accidentally copied to the
# Bastion-reached workstation.
tar -C "$MCQS_PARENT_DIR" -czf "$MCQS_OPERATOR_BUNDLE" \
  --exclude='*/__pycache__' \
  "${MCQS_BASENAME}/app" \
  "${MCQS_BASENAME}/operator" \
  "${MCQS_BASENAME}/scripts" \
  "${MCQS_BASENAME}/helm" \
  "${MCQS_BASENAME}/examples" \
  "${MCQS_BASENAME}/Dockerfile" \
  "${MCQS_BASENAME}/.dockerignore" \
  "${MCQS_BASENAME}/requirements.txt" \
  "${MCQS_BASENAME}/pyproject.toml" \
  "${MCQS_BASENAME}/README.md" \
  "${MCQS_BASENAME}/LICENSE" \
  "${MCQS_BASENAME}/docs/architecture.md" \
  "${MCQS_BASENAME}/docs/threat-model.md" \
  "${MCQS_BASENAME}/docs/provisioning-and-operator.md"

printf 'Created %s\n' "$MCQS_OPERATOR_BUNDLE"
