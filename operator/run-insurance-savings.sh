#!/usr/bin/env bash
set -euo pipefail

# Submit the synthetic insurance-savings example through the normal immutable
# Indexed Job path. All run-example options remain available.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

exec "${MCQS_OPERATOR_DIR}/run-example.sh" \
  --spec "${MCQS_ROOT_DIR}/examples/insurance-savings/unit-linked-endowment.json" \
  "$@"
