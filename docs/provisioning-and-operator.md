# Provisioning plane and private operator guide

This quickstart deliberately separates provisioning from runtime execution.

- The **provisioning plane** is a workstation with the OCI CLI, optionally OCI Cloud Shell. It discovers live OCI choices, packages the Resource Manager archive, and creates or destroys infrastructure. Cloud Shell is convenient here, but optional.
- The **private operator VM** is the only runtime workstation. It is reached through an OCI Bastion Managed SSH session and performs the Kubernetes, image, job, and result commands against the private OKE endpoint.

Resource Manager provisions infrastructure only: the private enhanced OKE cluster and node pool, private Object Storage and OCIR resources, OCI Bastion, and the private operator VM. By default it also creates the private File Storage filesystem, mount target and export. See the [architecture overview and result flow](architecture.md). It does not publish an image, create an image-pull secret, install Helm workloads, submit a simulation, or aggregate a result.

## 1. Discover a live-compatible OKE selection

Run these commands from the provisioning plane before creating a stack:

```bash
export REGION="us-ashburn-1"

# Use the exact AD name returned for the target region, then copy it here.
oci iam availability-domain list \
  --compartment-id "$TENANCY_OCID" \
  --region "$REGION" \
  --query 'data[].name' --output table

export WORKER_AD="<Availability-Domain-name>"

./provisioning/list-shapes.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION" \
  --availability-domain "$WORKER_AD"
./provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION"
```

Select a worker Availability Domain and a shape that are both available and supported by OKE, then ask OCI for a node image using that same region, architecture, and Kubernetes version:

```bash
export NODE_SHAPE="VM.Standard.E6.Flex"
export KUBERNETES_VERSION="<full-version-returned-by-OCI>"
export NODE_ARCHITECTURE="amd64"

./provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION" \
  --node-shape "$NODE_SHAPE" \
  --architecture "$NODE_ARCHITECTURE" \
  --kubernetes-version "$KUBERNETES_VERSION"

# Copy one image OCID from the compatible-image result.
export NODE_IMAGE_ID="ocid1.image.oc1..replace-with-live-result"
```

The Kubernetes version is a required live selection, not a static project default. OKE requires a full patch version; `v1.36` is invalid. The operator bootstrap installs the matching kubectl patch release and verifies its checksum.

The node image and architecture are mandatory compatibility decisions. Set Resource Manager's `node_architecture` explicitly (`amd64` for Intel/AMD or `arm64` for Ampere), then use only an image OCID returned for that exact region, Kubernetes version, and architecture. Never reuse a node-image OCID from a different region, version, shape family, or architecture. Flexible shapes also need OCPUs and memory; fixed shapes require those two Resource Manager values to be `null`.

Before packaging the stack, validate the version, image, and architecture against the live OKE API:

```bash
./provisioning/validate-oke-selection.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION" \
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

For a new quickstart, choose **Resource Manager → Stacks → Create stack** and upload this project’s `dist/orm.zip`. Update an existing stack only with its own configuration; a different project’s ZIP is not an add-on. Stop before Apply if Plan proposes an unintended deletion or replacement. Enter the live-verified Kubernetes version, `node_architecture`, node image OCID, and node configuration, plus a narrow `bastion_client_cidr` for the workstation or corporate VPN that will create the Managed SSH session. `bastion_session_ttl_seconds` defaults to 10,800 seconds (three hours), which is the OCI Bastion maximum; choose a whole value from 1,800 through 10,800 seconds when a shorter session is appropriate. Select the explicit `operator_kubernetes_access_mode` as well:

- `iam_admin` is the recommended quickstart path. The private operator receives OKE `manage clusters` only for the cluster created by this stack. That includes OKE's `AdministerK8s` operation, which Helm and kubectl require. It is not tenancy-wide, but it can administer Kubernetes objects and update this cluster.
- `namespace_rbac` is the stricter steady-state path. The operator receives only OKE `use clusters`, which is enough to create its kubeconfig but not enough to deploy Kubernetes objects. A tenancy administrator or Kubernetes cluster-admin applies the generated `operator_namespace_rbac_manifest` output once; it grants only the Monte Carlo namespace resources used by this project.

Keep `operator_bootstrap_generation = 1` for a new stack. Increment it only when you intentionally want Resource Manager to replace the operator VM and apply an updated runtime bundle. Review Resource Manager's plan and then apply it.

**Worker Availability Domain** places the OKE primary and benchmark pools. The stack records the initial operator and FSS placements separately, so a later worker-pool capacity move does not relocate the private operator or shared-result storage. Set **Operator Availability Domain** or **File Storage Availability Domain** only when you want a specific placement from the start or an intentional relocation.

The **Identity and policy controls** section contains one switch for each IAM policy and another for the operator dynamic group. Each description states the access it grants. If a selected operator policy uses an existing dynamic group, set `create_operator_dynamic_group = false` and provide `operator_dynamic_group_ocid`.

The default `result_delivery_mode = fss` uses a private shared OCI File Storage export instead of Pod-level Object Storage access. Leave `fss_subnet_cidr` non-overlapping and `/28` or larger. The FSS baseline creates a static cluster-scoped PersistentVolume, so select `operator_kubernetes_access_mode = iam_admin`; the stack rejects the namespace-only mode for this automated path. In FSS mode, the stack does not create the two Object Storage result policies; the bootstrap bundle still uses private Object Storage. See [FSS result delivery](fss-result-delivery.md) for the mount, CSI, and operating model.

The stack's boundary ends here. Treat a successful Apply as an infrastructure handoff, not as evidence that a simulation runtime or image-pull secret exists.

## 3. Reach the private operator through Bastion

From the workstation that owns the SSH key, use the Resource Manager `operator_session_create_command` output (or create a Managed SSH session in the OCI Console). Copy the resulting SSH command and connect as `opc`. The operator VM has no public IP and is the permitted path to the private OKE API.

On the operator VM, load the provisioned runtime context and enter the bundle:

```bash
source /etc/profile.d/mcqs-runtime.sh
cd /home/opc/oci-monte-carlo-quickstart
./operator/doctor.sh
```

The profile supplies the private-cluster, registry, result-delivery, architecture, access-mode, and Python settings for the runtime. The bootstrap installs the operator tooling and generates the private OKE kubeconfig. `operator/doctor.sh` verifies the bootstrap, instance-principal access, local tooling, and Kubernetes authorization without trying to list `kube-system` services. In FSS mode it also verifies the operator mount and CSI driver. If it reports an incomplete bootstrap, review `/var/log/mcqs-operator-bootstrap.log` rather than trying to run runtime commands from the provisioning plane.

### One-time RBAC bootstrap for `namespace_rbac`

This step is unnecessary for the `iam_admin` quickstart path. For `namespace_rbac`, copy the `operator_namespace_rbac_manifest` stack output to `operator-namespace-rbac.yaml`. A principal in the tenancy `Administrators` group or with an existing Kubernetes `cluster-admin` binding must apply it; compartment administrator permissions alone do not create Kubernetes RBAC roles.

Use the `operator_rbac_bastion_session_create_command` stack output to create a time-limited port-forwarding session to the private OKE endpoint. Start the SSH tunnel command shown in that Bastion session's details, listening on a local port such as `6443`. From that administrator's terminal, create a personal kubeconfig and point its selected cluster at the tunnel:

```bash
oci ce cluster create-kubeconfig \
  --cluster-id "$CLUSTER_ID" \
  --file "$HOME/.kube/mcqs-admin-config" \
  --region "$REGION" \
  --token-version 2.0.0 \
  --kube-endpoint PRIVATE_ENDPOINT

export KUBECONFIG="$HOME/.kube/mcqs-admin-config"
kubectl config set-cluster "$(kubectl config view -o jsonpath='{.contexts[0].context.cluster}')" \
  --server=https://127.0.0.1:6443
kubectl apply -f operator-namespace-rbac.yaml
```

The generated command passes the private API **IP address** to `--target-private-ip` and the API port separately to `--target-port`; do not append `:6443` to the IP address. The tunnel and the administrator kubeconfig are only for this one-time binding; they are not the runtime path. It exposes the Kubernetes API for `kubectl`, not a browser UI. The quickstart does not install Kubernetes Dashboard, so do not open `https://127.0.0.1:8000` (or the tunnel port) in Chrome and do not bypass browser certificate warnings. Disconnect the tunnel when the apply succeeds, then return to the private operator VM and run `./operator/doctor.sh`.

## 4. Install the shared runtime baseline

Install the baseline once per namespace from the operator VM:

```bash
./operator/install-runtime.sh
```

The baseline owns the namespace-level ServiceAccount and security controls. Each simulation later creates only its own run-specific resources, so separate Helm releases do not compete for the shared account. In FSS mode, the baseline also owns the static `ReadWriteMany` PV/PVC; every per-run release only references the shared claim.

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

Each invocation creates a unique run ID and a run-specific Helm release. The chart stores the validated input in an immutable ConfigMap and submits an Indexed Job pinned to the published image digest. Every worker owns a stable partition index and writes one write-once partial result either below that run's Object Storage prefix using OKE Workload Identity or into the shared FSS run directory, according to the configured delivery mode.

`operator/run-example.sh` waits for completion and aggregates the sample automatically. To aggregate a completed run again or use a different confidence level, run:

```bash
./operator/aggregate-results.sh \
  --run-id "$RUN_ID" \
  --expected-partitions 4 \
  --confidence 0.95
```

Aggregation accepts only one run ID and input hash and checks that every expected partition occurs exactly once before combining additive moments. The printed price, confidence interval, input hash, and runtime metadata therefore remain tied to one reproducible run rather than a mixture of retries or submissions.

## Cleanup

`operator/cleanup-runtime.sh` removes the Monte Carlo Helm releases while leaving the namespace and `ocir-pull` secret in place for deliberate review or rotation. Use a Resource Manager Destroy job to remove the infrastructure when the environment is no longer needed. For a local Terraform fallback, the provisioning-plane scripts are `provisioning/terraform-apply.sh` and `provisioning/terraform-destroy.sh`; they are not operator-runtime commands.
