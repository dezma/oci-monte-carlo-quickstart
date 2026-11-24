#!/usr/bin/env bash
set -euo pipefail

# The primary repeatable comparison entry point. It delegates process control,
# durable status, and cancellation to the regular suite runner while selecting
# the strict OCI-OCPU resource contract for every profile.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

exec "${MCQS_OPERATOR_DIR}/run-benchmark-suite.sh" --strict-ocpu "$@"
