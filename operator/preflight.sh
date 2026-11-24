#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n\nChecks the private operator workstation tooling and instance-principal access.\n' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    mcqs_fail "Unknown option: $1"
    ;;
esac

mcqs_note "Checking operator tooling"
MCQS_PYTHON="${MCQS_PYTHON:-python3}"
for binary in oci kubectl helm jq "$MCQS_PYTHON"; do
  mcqs_require_command "$binary"
done

if command -v docker >/dev/null 2>&1; then
  printf 'Container CLI: docker\n'
elif command -v podman >/dev/null 2>&1; then
  printf 'Container CLI: podman (operator/build-and-push.sh requires Docker; install Docker before publishing an image)\n'
else
  printf 'Container CLI: not found (required only for image publishing)\n'
fi

mcqs_note "Checking OCI instance-principal session"
mcqs_require_operator_environment
oci os ns get --query data --raw-output >/dev/null || mcqs_fail "OCI instance-principal authentication failed. Wait for IAM propagation or review the operator dynamic-group policy."
printf 'OCI instance principal: ready\n'
printf 'kubectl client: %s\n' "$(kubectl version --client --output=json | jq -r '.clientVersion.gitVersion')"
printf 'Helm: %s\n' "$(helm version --short)"

if [[ "${MCQS_RESULT_DELIVERY_MODE:-fss}" == "fss" ]]; then
  MCQS_FSS_RESULTS_DIR="${MCQS_FSS_RESULTS_DIR:-}"
  mcqs_require_value MCQS_FSS_RESULTS_DIR
  mountpoint -q "$MCQS_FSS_RESULTS_DIR" || \
    mcqs_fail "FSS result delivery is configured but ${MCQS_FSS_RESULTS_DIR} is not mounted. Run operator/doctor.sh."
  printf 'Result delivery: FSS mounted at %s\n' "$MCQS_FSS_RESULTS_DIR"
else
  printf 'Result delivery: Object Storage\n'
fi

mcqs_note "Security prerequisites"
cat <<'MESSAGE'
Run simulation commands only from the private operator instance reached by an
OCI Bastion Managed SSH session. Do not expose the OKE API or operator instance
with a public IP address. Verify that /home/opc/.mcqs-operator-ready exists
before changing the runtime.
MESSAGE
