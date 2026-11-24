# Terraform deployment

This directory creates a new, isolated private environment. It provisions only infrastructure: a private enhanced OKE cluster, managed node pools, OCI Bastion, a private operator, OCIR, a bootstrap bucket and, by default, private File Storage. The operator bundle includes the architecture overview and result-flow diagrams under `docs/`. The Helm workload is deliberately not deployed by Resource Manager.

## Required permissions

The deploying principal needs least-privilege permissions for the resources this stack creates in the target compartment: VCN, gateways, subnets, NSGs, OKE cluster/node pool, File Storage filesystem/mount target/export (FSS mode), Object Storage bucket, OCIR repository, logging log group, and IAM policy. In a production tenancy, have the platform/IAM owner provide a reviewed policy rather than granting broad tenancy administrator access.

### Identity and policy controls

Every IAM resource has a separate opt-in control in Resource Manager and `terraform.tfvars`. This lets a platform team use its own identity configuration without changing the rest of the infrastructure stack.

| Setting | What it creates |
|---|---|
| `create_workload_object_storage_policy` | Lets simulation Jobs create result objects below the configured Object Storage prefix. |
| `create_operator_dynamic_group` | Identifies the private operator instance through its instance principal. |
| `create_operator_cluster_access_policy` | Lets the operator obtain and use the kubeconfig for this OKE cluster. |
| `create_operator_bootstrap_bundle_read_policy` | Lets the operator download its bootstrap bundle from Object Storage. |
| `create_operator_results_read_policy` | Lets the operator read simulation results from Object Storage. |
| `create_benchmark_cluster_autoscaler_workload_identity_policy` | Lets the OKE Cluster Autoscaler workload identity resize the selected benchmark pools and the compute/network resources required by those pools. It is used only when benchmark-pool autoscaling is enabled. |

When an operator policy is selected but `create_operator_dynamic_group = false`, set `operator_dynamic_group_ocid` to the existing group that identifies the operator instance. When `namespace_rbac` is selected, that same group is used in the generated Kubernetes RoleBinding. Terraform does not discover or validate separately managed IAM policies or dynamic-group matching rules.

## Optional dedicated benchmark pools

Resource Manager presents benchmark capacity as guided profile choices rather than a free-form configuration. Select any of the six profiles below to add a dedicated managed OKE node pool for that shape. Terraform applies the durable `benchmark.oracle.com/profile=<profile-id>` label to the pool's initial Nodes; benchmark Jobs use that label to run on the intended hardware.

| Resource Manager choice | Benchmark profile | Shape | CPU architecture |
|---|---|---|---|
| Add AMD E5 Flex pool | `e5-flex` | `VM.Standard.E5.Flex` | amd64 |
| Add AMD E6 Flex pool | `e6-flex` | `VM.Standard.E6.Flex` | amd64 |
| Add AMD E6 Acceleron pool | `e6-acceleron` | `VM.Standard.E6.Ax.Flex` | amd64 |
| Add Intel Optimized3 Flex pool | `intel-optimized3` | `VM.Optimized3.Flex` | amd64 |
| Add Intel Acceleron pool | `intel-acceleron` | `VM.Standard4.Ax.Flex` | amd64 |
| Add Ampere A4 Acceleron pool | `a4-acceleron` | `VM.Standard.A4.Ax.Flex` | arm64 |

The form then asks for one compatible OKE image per architecture and one shared capacity plan: OCPUs, memory, initial Nodes, minimum Nodes, maximum Nodes, and Pods per Node. The primary worker-pool image is reused automatically when it has the architecture required by the selected profile. Provide the AMD and Intel image only when an amd64 profile needs a different image; provide the Ampere image only when A4 is selected and the primary image is not already arm64. Each image must match the Kubernetes version selected for the cluster.

For a custom shape or a profile outside these guided choices, `benchmark_node_pools_json` remains available in `terraform.tfvars` for advanced Terraform CLI use. It is intentionally not displayed in Resource Manager.

Set `enable_benchmark_cluster_autoscaler = true` to install OKE's Cluster Autoscaler add-on with the exact selected pool OCIDs and their `min_size:max_size` bounds. The quickstart's primary worker pool is deliberately excluded, so cluster services retain a non-autoscaled scheduling home. Terraform deliberately ignores post-create node-count drift on these dedicated pools, because scale-in and scale-out are the expected autoscaler actions. The add-on uses OKE workload identity. If selected, `create_benchmark_cluster_autoscaler_workload_identity_policy` creates its condition-scoped policy for the `kube-system/cluster-autoscaler` service account and this cluster. An organisation may instead manage an equivalent policy separately by setting that control to `false`.

The OKE Terraform node-pool API supports persistent initial labels, but not Kubernetes taints. The stack writes every profile's desired `benchmark.oracle.com/profile=<profile-id>:NoSchedule` taint into the private operator configuration. `operator/run-benchmark.sh` detects a Terraform-defined profile, reconciles that taint on its current Nodes, selects the matching label, and includes a matching Job toleration. This requires the quickstart's `iam_admin` operator mode because taints are Node-level Kubernetes changes. Rerun `operator/reconcile-benchmark-pools.sh --profile <profile-id>` after a planned node replacement or scale-out if isolation needs to be restored before another workload is submitted.

After adding or modifying benchmark profiles, increment `operator_bootstrap_generation` in the same apply. The setting intentionally replaces the private operator so its local benchmark-profile configuration matches the Terraform-created node pools.

## Result delivery

`result_delivery_mode` controls where an Indexed Job publishes its immutable partition result. The default, `fss`, uses a private OCI File Storage export mounted by the OKE FSS CSI driver; worker Pods receive no Object Storage identity. The private operator reads the same export to aggregate the run. Choose `object_storage` when the platform design prefers a private result bucket. In that mode, OCI Workload Identity restricts each Pod to creating objects below the configured result prefix.

The default `result_delivery_mode = "fss"` creates the filesystem, dedicated mount-target subnet, private mount target, export, and NFS network rules. The Helm baseline on the operator, not Terraform, creates and binds the static FSS PersistentVolume. In this mode, workers and the operator use the shared NFS export; worker Pods do not receive an Object Storage workload-identity token and the workload/reader Object Storage result policies are not created. Object Storage is still provisioned privately because the operator bootstrap bundle is delivered from it.

FSS uses a separate `/28` mount-target subnet by default (`fss_subnet_cidr = "10.42.50.0/28"`). The stack permits only the operator and worker-node client groups to use the required NFS/RPC ports. Export options give the operator controlled initialization access and map workers to the non-root UID/GID used by the simulator image. Do not overlap this subnet with another quickstart subnet. The default `fss_mount_target_ip` is host address 10 in that CIDR, or set a free address explicitly.

The baseline chart creates the static PV and namespace-scoped PVC during `operator/install-runtime.sh`. The generated binding names include the filesystem identity, so a replacement export receives a fresh Kubernetes binding. Because a static PV is cluster-scoped, FSS mode requires `operator_kubernetes_access_mode = "iam_admin"`; the stack validates this early rather than leaving a namespace-scoped operator to fail during runtime installation. The Kubernetes capacity (`fss_persistent_volume_capacity`, default `50Gi`) is required by Kubernetes but does not cap OCI File Storage, which is elastic. The FSS CSI driver must be available in the OKE cluster; `operator/doctor.sh` and `operator/install-runtime.sh` check it before a run is submitted.

## Shape selection

Run these commands before creating the Resource Manager stack. Pass the target region explicitly when the OCI CLI profile is configured for a different region. First list the exact Availability Domain names using the tenancy OCID, then set `WORKER_AD` to the intended placement:

```bash
oci iam availability-domain list \
  --compartment-id "$TENANCY_OCID" \
  --region "$REGION" \
  --query 'data[].name' --output table
```

```bash
../provisioning/list-shapes.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION" \
  --availability-domain "$WORKER_AD"
../provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION"
../provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION" \
  --node-shape "VM.Standard.E6.Flex" \
  --architecture amd64 \
  --kubernetes-version <full-version-returned-by-OCI>
```

Set `node_shape` to an OKE-supported shape returned by OCI. Set `node_architecture` explicitly to `amd64` for Intel/AMD worker images or `arm64` for Ampere worker images; do not infer it from a shape name. For flex shapes, supply OCPUs and memory. For a fixed shape, set `node_shape_ocpus = null` and `node_shape_memory_gbs = null`.

Select `kubernetes_version` from the live OKE response and provide a compatible `node_image_id` for that exact version and the explicit `node_architecture`. Minor-only input such as `v1.36` is rejected before OCI is called; OKE accepts full patch versions only. The module installs the matching kubectl patch release. The module derives the normal OCIR registry domain from the tenancy's current region subscription. Set `ocir_registry` only when your OCI realm uses a different registry endpoint.

`availability_domain` places the OKE primary and benchmark worker pools. The stack records initial operator and FSS placement separately, so a later worker-capacity move does not relocate them. Set `operator_availability_domain` or `fss_availability_domain` only for a deliberate placement choice or relocation. Changing FSS placement replaces FSS resources, so plan data migration before making that change.

## Private operator management path

Terraform creates a private operator workstation in `operator_subnet_cidr` and permits only that subnet to reach the OKE API on TCP/6443. OCI Bastion uses the separate `bastion_subnet_cidr`; its managed SSH sessions are limited to the mandatory `bastion_client_cidr`. The operator has no public IP, uses an instance principal, and carries the generated kubeconfig and `operator/` plus `scripts/` runtime bundle. Its cluster permission is restricted to the cluster created by this stack.

Set `bastion_session_ttl_seconds` from 1,800 to 10,800 seconds. It defaults to 10,800 seconds (three hours) and is used by both generated Bastion commands. `bastion_ssh_public_key_file` controls the local RSA public-key path included in those commands; Terraform does not access the local file.

Leave `operator_shape` unset for the architecture-aware default: `VM.Standard.A4.Flex` for an `arm64` node target and `VM.Standard.E5.Flex` for `amd64`. If A4 capacity is unavailable, override it with an Arm flexible shape returned by the live shape query. Any explicit override must be a flexible shape and use an image with the same CPU architecture. Bootstrap detects the actual operator architecture before downloading kubectl and Helm.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out quickstart.tfplan
terraform apply quickstart.tfplan
```

After the Apply job completes, create a Managed SSH session using the `operator_session_create_command` output. Connect as `opc`, then run the scripts from `/home/opc/oci-monte-carlo-quickstart`.
