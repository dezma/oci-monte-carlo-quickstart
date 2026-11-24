#!/usr/bin/env bash
set -euo pipefail

# Submit the bounded insurance stress grid through the normal grid launcher.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

exec "${MCQS_OPERATOR_DIR}/run-grid.sh" \
  --grid "${MCQS_ROOT_DIR}/examples/grids/insurance-savings-stress-grid.json" \
  "$@"
