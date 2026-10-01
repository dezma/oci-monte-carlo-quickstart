# Provisioning plane and private operator guide

This quickstart deliberately separates provisioning from runtime execution.

- The **provisioning plane** is a workstation with the OCI CLI, optionally OCI Cloud Shell. It discovers live OCI choices, packages the Resource Manager archive, and creates or destroys infrastructure. Cloud Shell is convenient here, but optional.
- The **private operator VM** is the only runtime workstation. It is reached through an OCI Bastion Managed SSH session and performs the Kubernetes, image, job, and result commands against the private OKE endpoint.

Resource Manager provisions infrastructure only: the private enhanced OKE cluster and node pool, private Object Storage and OCIR resources, OCI Bastion, and the private operator VM. It does not publish an image, create an image-pull secret, install Helm workloads, submit a simulation, or aggregate a result.

## 1. Discover a live-compatible OKE selection

Run these commands from the provisioning plane before creating a stack:

```bash
./provisioning/list-shapes.sh --compartment-id "$COMPARTMENT_OCID"
./provisioning/list-oke-options.sh --compartment-id "$COMPARTMENT_OCID"
```

Select a shape that is both available and supported by OKE, then ask OCI for a node image using that same shape and Kubernetes version:

```bash
export NODE_SHAPE="VM.Standard.E6.Flex"
export KUBERNETES_VERSION="v1.36.1"
export NODE_ARCHITECTURE="amd64"

./provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --node-shape "$NODE_SHAPE" \
  --architecture "$NODE_ARCHITECTURE" \
  --kubernetes-version "$KUBERNETES_VERSION"

# Copy one image OCID from the compatible-image result.
export NODE_IMAGE_ID="ocid1.image.oc1..replace-with-live-result"
```

`v1.36.1` is the prefilled recommended version, not a promise of availability. Keep it only when the live OKE version query reports that exact patch for the target tenancy and region. OKE requires a full patch version; `v1.36` is invalid. The operator bootstrap installs the matching kubectl patch release and verifies its checksum.

The node image and architecture are mandatory compatibility decisions. Set Resource Manager's `node_architecture` explicitly (`amd64` for Intel/AMD or `arm64` for Ampere), then use only an image OCID returned for that exact Kubernetes version and architecture. Never reuse a node-image OCID from a different version, shape family, or architecture. Flexible shapes also need OCPUs and memory; fixed shapes require those two Resource Manager values to be `null`.

Before packaging the stack, validate the version, image, and architecture against the live OKE API:

```bash
./provisioning/validate-oke-selection.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --node-shape "$NODE_SHAPE" \
  --architecture "$NODE_ARCHITECTURE" \
  --node-image-id "$NODE_IMAGE_ID" \
  --kubernetes-version "$KUBERNETES_VERSION"
```

This is the final compatibility guard; the shape discovery above remains the separate check for live shape availability and capacity.

## 2. Package and apply infrastructure through Resource Manager

Build the Resource Manager archive from the provisioning plane:

```bash
./provisioning/build-orm.sh
```

Upload `dist/orm.zip` to OCI Resource Manager. Enter the live-verified Kubernetes version, `node_architecture`, node image OCID, and node configuration, plus a narrow `bastion_client_cidr` for the workstation or corporate VPN that will create the Managed SSH session. Review Resource Manager's plan and then apply it.

The stack's boundary ends here. Treat a successful Apply as an infrastructure handoff, not as evidence that a simulation runtime or image-pull secret exists.

## 3. Reach the private operator through Bastion

From the workstation that owns the SSH key, use the Resource Manager `operator_session_create_command` output (or create a Managed SSH session in the OCI Console). Copy the resulting SSH command and connect as `opc`. The operator VM has no public IP and is the permitted path to the private OKE API.

On the operator VM, load the provisioned runtime context and enter the bundle:

```bash
source /etc/profile.d/mcqs-runtime.sh
cd /home/opc/oci-monte-carlo-quickstart
./operator/doctor.sh
```

The profile supplies the private-cluster, registry, Object Storage, architecture, and Python settings for the runtime. The bootstrap installs the operator tooling, uses the VM instance principal to obtain private OKE access, and writes its ready marker only after it can reach the cluster. `operator/doctor.sh` is the first runtime check: it verifies the bootstrap, instance-principal access, local tooling, and private OKE connectivity. If it reports an incomplete bootstrap, review `/var/log/mcqs-operator-bootstrap.log` rather than trying to run runtime commands from the provisioning plane.

## 4. Install the shared runtime baseline

Install the baseline once per namespace from the operator VM:

```bash
./operator/install-runtime.sh
```

The baseline owns the namespace-level ServiceAccount and security controls. Each simulation later creates only its own run-specific resources, so separate Helm releases do not compete for the shared account.

## 5. Publish an immutable image

Set `OCI_USER_NAME` to the OCI Console Profile-menu value **without** the tenancy namespace. For a federated identity this has the form `<identity-domain>/<username>`.

```bash
export OCI_USER_NAME="<username-or-identity-domain/username>"
./operator/build-and-push.sh
```

The default is a native single-architecture Docker build and push for the selected node architecture. It is the normal path for one node-pool family. The command records a repository digest in local image metadata; jobs use that `sha256` digest rather than a mutable tag.

Use a multi-architecture manifest only when both `amd64` and `arm64` are actually needed and the Buildx builder can authenticate to OCIR:

```bash
./operator/build-and-push.sh --multi-arch
```

This optional path is not required for a single Intel/AMD or Ampere benchmark. It still must resolve an immutable manifest digest before a job can run.

## 6. Create the OCIR pull secret

Kubernetes image pulling is a separate authentication path from the operator VM's OCI instance principal. A private OCIR image is not automatically pullable by worker nodes merely because the operator can access OCI. Create or rotate the namespace pull secret before submitting a run:

```bash
./operator/create-pull-secret.sh
```

The build and pull-secret commands prompt for the required OCIR auth token. The build command logs Docker out when it finishes; the pull-secret command uses a temporary local Docker configuration, then stores the credential as the namespace-scoped `ocir-pull` `kubernetes.io/dockerconfigjson` secret until it is rotated or removed. Do not put the token in Terraform, a shell history, source control, or a simulation specification. Rotate it before expiry.

## 7. Submit an immutable run and aggregate it

Match the Job's node selector to the verified node architecture:

```bash
./operator/run-example.sh --parallelism 4 --architecture amd64
# Use --architecture arm64 for an Ampere node pool.
./operator/status.sh
```

Each invocation creates a unique run ID and a run-specific Helm release. The chart stores the validated input in an immutable ConfigMap and submits an Indexed Job pinned to the published image digest. Every worker owns a stable partition index and writes a write-once partial result under that run's Object Storage prefix using OKE Workload Identity.

`operator/run-example.sh` waits for completion and aggregates the sample automatically. To aggregate a completed run again or use a different confidence level, run:

```bash
./operator/aggregate-results.sh \
  --run-id "$RUN_ID" \
  --expected-partitions 4 \
  --confidence 0.95
```

Aggregation accepts only one run ID and input hash and checks that every expected partition occurs exactly once before combining additive moments. The printed price, confidence interval, input hash, and runtime metadata therefore remain tied to one reproducible run rather than a mixture of retries or submissions.

## Cleanup and recovery boundaries

`operator/cleanup-runtime.sh` removes the Monte Carlo Helm releases while leaving the namespace and `ocir-pull` secret in place for deliberate review or rotation. Use a Resource Manager Destroy job to remove the infrastructure when the environment is no longer needed. For a local Terraform fallback, the provisioning-plane scripts are `provisioning/terraform-apply.sh` and `provisioning/terraform-destroy.sh`; they are not operator-runtime commands.
