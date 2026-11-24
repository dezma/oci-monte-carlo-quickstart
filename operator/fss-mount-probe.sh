#!/usr/bin/env bash
set -euo pipefail

# Verifies that the selected worker pool can mount and write to the shared FSS
# claim before a benchmark starts. The probe uses the same immutable image,
# node selection, tolerations, security context, and two-host placement rule
# as a benchmark Job, but its time is never included in benchmark results.
source "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/scripts/lib.sh"

ARCHITECTURE=""
TIMEOUT="5m"
NODE_SELECTORS=()
TOLERATIONS=()

usage() {
  printf '%s\n' "Usage: $0 --architecture amd64|arm64 [--node-selector key=value] [--toleration key=value:NoSchedule] [--timeout 5m]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --architecture) ARCHITECTURE="${2:-}"; shift 2 ;;
    --node-selector) NODE_SELECTORS+=("${2:-}"); shift 2 ;;
    --toleration) TOLERATIONS+=("${2:-}"); shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mcqs_fail "Unknown option: $1" ;;
  esac
done

[[ "$ARCHITECTURE" == "amd64" || "$ARCHITECTURE" == "arm64" ]] || \
  mcqs_fail "architecture must be amd64 or arm64."
[[ "$TIMEOUT" =~ ^[1-9][0-9]*(s|m)$ ]] || \
  mcqs_fail "timeout must be a positive duration ending in s or m."

if [[ "$TIMEOUT" == *s ]]; then
  PROBE_ACTIVE_DEADLINE_SECONDS="${TIMEOUT%s}"
else
  PROBE_ACTIVE_DEADLINE_SECONDS=$(( ${TIMEOUT%m} * 60 ))
fi

mcqs_require_operator_environment
for binary in date jq kubectl sha256sum; do
  mcqs_require_command "$binary"
done
mcqs_configure_kubeconfig

if [[ "${MCQS_RESULT_DELIVERY_MODE:-fss}" != "fss" ]]; then
  printf 'FSS worker mount probe: not required for Object Storage result delivery.\n'
  exit 0
fi

mcqs_load_image_metadata
mcqs_require_value MCQS_IMAGE_REPOSITORY
mcqs_require_value MCQS_IMAGE_DIGEST
MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME="${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME:-}"
mcqs_require_value MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME

kubectl -n "$MCQS_NAMESPACE" get serviceaccount "$MCQS_SERVICE_ACCOUNT" >/dev/null || \
  mcqs_fail "Runtime baseline is missing. Run operator/install-runtime.sh first."
[[ "$(kubectl -n "$MCQS_NAMESPACE" get pvc "$MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME" -o jsonpath='{.status.phase}')" == "Bound" ]] || \
  mcqs_fail "FSS result claim ${MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME} is not Bound. Run operator/install-runtime.sh and check the FSS CSI driver."
kubectl get csidriver fss.csi.oraclecloud.com >/dev/null || \
  mcqs_fail "The OKE FSS CSI driver is unavailable. Enable or repair the OKE File Storage CSI add-on."

node_selector_json='{}'
for selector in "${NODE_SELECTORS[@]}"; do
  selector_key="${selector%%=*}"
  selector_value="${selector#*=}"
  [[ "$selector" == *=* && -n "$selector_key" && -n "$selector_value" ]] || \
    mcqs_fail "node-selector must use key=value syntax."
  node_selector_json="$(jq --arg key "$selector_key" --arg value "$selector_value" '. + {($key): $value}' <<<"$node_selector_json")"
done
node_selector_json="$(jq --arg architecture "$ARCHITECTURE" '. + {"kubernetes.io/arch": $architecture}' <<<"$node_selector_json")"

tolerations_json='[]'
for toleration in "${TOLERATIONS[@]}"; do
  toleration_pair="${toleration%:*}"
  toleration_effect="${toleration##*:}"
  toleration_key="${toleration_pair%%=*}"
  toleration_value="${toleration_pair#*=}"
  [[ "$toleration" == *=*:* && -n "$toleration_key" && -n "$toleration_value" && "$toleration_effect" == "NoSchedule" ]] || \
    mcqs_fail "toleration must use key=value:NoSchedule syntax."
  tolerations_json="$(jq --arg key "$toleration_key" --arg value "$toleration_value" --arg effect "$toleration_effect" \
    '. + [{key: $key, operator: "Equal", value: $value, effect: $effect}]' <<<"$tolerations_json")"
done

probe_token="$(printf '%s' "$(date -u +%s%N)-${MCQS_IMAGE_DIGEST}-${node_selector_json}" | sha256sum | cut -c1-16)"
probe_name="mcqs-fss-probe-${probe_token}"
probe_label_key="monte-carlo.oracle.com/fss-mount-probe"
probe_file=".mcqs-fss-probe-${probe_token}"
probe_image="${MCQS_IMAGE_REPOSITORY}@${MCQS_IMAGE_DIGEST}"

mcqs_note "Checking FSS worker mounts on two selected nodes"
jq -n \
  --arg name "$probe_name" \
  --arg namespace "$MCQS_NAMESPACE" \
  --arg service_account "$MCQS_SERVICE_ACCOUNT" \
  --arg image "$probe_image" \
  --arg claim_name "$MCQS_FSS_PERSISTENT_VOLUME_CLAIM_NAME" \
  --arg label_key "$probe_label_key" \
  --arg probe_token "$probe_token" \
  --arg probe_file "$probe_file" \
  --argjson active_deadline_seconds "$PROBE_ACTIVE_DEADLINE_SECONDS" \
  --argjson node_selector "$node_selector_json" \
  --argjson tolerations "$tolerations_json" \
  '{
    apiVersion: "batch/v1",
    kind: "Job",
    metadata: {
      name: $name,
      namespace: $namespace,
      labels: {($label_key): $probe_token, "app.kubernetes.io/component": "fss-mount-probe"}
    },
    spec: {
      completions: 2,
      parallelism: 2,
      completionMode: "Indexed",
      backoffLimit: 0,
      activeDeadlineSeconds: $active_deadline_seconds,
      # Successful probes are deleted explicitly below. Retaining an
      # unsuccessful probe briefly preserves its container logs for a
      # targeted diagnosis without leaving failed Jobs indefinitely.
      ttlSecondsAfterFinished: 900,
      template: {
        metadata: {
          labels: {($label_key): $probe_token, "app.kubernetes.io/component": "fss-mount-probe"}
        },
        spec: {
          restartPolicy: "Never",
          serviceAccountName: $service_account,
          automountServiceAccountToken: false,
          imagePullSecrets: [{name: "ocir-pull"}],
          nodeSelector: $node_selector,
          tolerations: $tolerations,
          securityContext: {
            runAsNonRoot: true,
            runAsUser: 10001,
            runAsGroup: 10001,
            fsGroup: 10001,
            seccompProfile: {type: "RuntimeDefault"}
          },
          topologySpreadConstraints: [{
            maxSkew: 1,
            minDomains: 2,
            topologyKey: "kubernetes.io/hostname",
            whenUnsatisfiable: "DoNotSchedule",
            nodeAffinityPolicy: "Honor",
            nodeTaintsPolicy: "Honor",
            labelSelector: {matchLabels: {($label_key): $probe_token}}
          }],
          containers: [{
            name: "fss-mount-probe",
            image: $image,
            imagePullPolicy: "IfNotPresent",
            command: ["python", "-c"],
            # Workers are deliberately all-squashed to the simulator UID and
            # can write only below the initialized runs directory. Probe that
            # same path rather than the export root, which remains protected.
            # Each Indexed Pod must use its own probe file. A shared filename
            # lets one healthy Pod delete the other Pod file between its
            # write and unlink operations, creating a false negative.
            args: ["import os\nfrom pathlib import Path\nprobe = Path(\"/results\") / \"runs\" / (os.environ[\"MCQS_PROBE_FILE\"] + \"-\" + os.environ[\"MCQS_PROBE_POD_UID\"])\nprobe.write_text(\"ready\\n\", encoding=\"utf-8\")\nprobe.unlink()\n"],
            env: [
              {name: "MCQS_PROBE_FILE", value: $probe_file},
              {name: "MCQS_PROBE_POD_UID", valueFrom: {fieldRef: {fieldPath: "metadata.uid"}}}
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: {drop: ["ALL"]}
            },
            resources: {
              requests: {cpu: "10m", memory: "32Mi"},
              limits: {cpu: "100m", memory: "128Mi"}
            },
            volumeMounts: [{name: "results", mountPath: "/results"}, {name: "temporary", mountPath: "/tmp"}]
          }],
          volumes: [
            {name: "results", persistentVolumeClaim: {claimName: $claim_name}},
            {name: "temporary", emptyDir: {sizeLimit: "16Mi"}}
          ]
        }
      }
    }
  }' | kubectl apply -f - >/dev/null

if kubectl -n "$MCQS_NAMESPACE" wait --for=condition=complete "job/${probe_name}" --timeout="$TIMEOUT" >/dev/null; then
  kubectl -n "$MCQS_NAMESPACE" delete job "$probe_name" --ignore-not-found >/dev/null
  printf 'FSS worker mounts: ready on two selected nodes\n'
  exit 0
fi

printf '\nFSS mount probe details:\n' >&2
kubectl -n "$MCQS_NAMESPACE" get jobs,pods -l "${probe_label_key}=${probe_token}" -o wide >&2 || true
for pod in $(kubectl -n "$MCQS_NAMESPACE" get pods -l "${probe_label_key}=${probe_token}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  printf '\nFSS mount probe logs for %s:\n' "$pod" >&2
  kubectl -n "$MCQS_NAMESPACE" logs "$pod" -c fss-mount-probe --tail=-1 >&2 || true
  printf '\nFSS mount probe events for %s:\n' "$pod" >&2
  kubectl -n "$MCQS_NAMESPACE" describe pod "$pod" | sed -n '/Events:/,$p' >&2 || true
done
mcqs_fail "FSS worker mount probe did not complete. Resolve the reported CSI, mount, image-pull, or node-placement condition before starting a benchmark."
