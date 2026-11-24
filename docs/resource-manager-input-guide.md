# Resource Manager input guide

Use the Resource Manager form in the order it is presented. The default path creates a private OKE environment with a primary worker pool, private operator VM, OCI Bastion access, and private FSS result delivery. Dedicated benchmark pools and separately managed IAM resources are optional choices.

For a fresh deployment, create a new stack. For updates, keep the same project and state. Review the plan for changes to existing pools, the operator and result storage before Apply.

## Prepare five values before opening the form

Run the discovery helpers from a Cloud Shell session or an OCI-authenticated workstation. First obtain the exact target Availability Domain name using the tenancy OCID:

```bash
oci iam availability-domain list \
  --compartment-id "$TENANCY_OCID" \
  --region "$REGION" \
  --query 'data[].name' --output table
```

Then set `WORKER_AD` to the intended domain and run:

```bash
./provisioning/list-shapes.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION" \
  --availability-domain "$WORKER_AD"
./provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION"
./provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --region "$REGION" \
  --node-shape "$NODE_SHAPE" \
  --architecture amd64 \
  --kubernetes-version "$KUBERNETES_VERSION"
```

Record these values before creating the stack:

1. Deployment compartment and region.
2. A full Kubernetes patch version returned by OCI.
3. A node shape available in the intended Availability Domain.
4. An OKE node image OCID for that exact Kubernetes version and CPU architecture.
5. The public CIDR of the workstation or VPN that will open the Bastion session. Use `/32` for one fixed public IPv4 address.

Create an RSA public key if you do not already have one:

```bash
test -f ~/.ssh/id_rsa.pub || ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
```

## Complete the form

| Form section | What to decide | Good first-time choice |
|---|---|---|
| Deployment location | Where OCI creates the environment and the resource name prefix. | Select the intended compartment and region. Set Worker Availability Domain when the selected worker shape needs a specific placement. |
| Private network and Bastion access | CIDRs for the private environment and who may create a Bastion session. | Keep the supplied private CIDRs if they do not overlap an existing network. Set the Bastion client CIDR to the narrowest practical public range. |
| OKE cluster and primary workers | The Kubernetes version, primary worker hardware, matching OKE image, and baseline capacity. | Use the discovered full version and matching image. Start with the supplied E6 Flex capacity for the example workload. |
| Results and workload security | Where immutable worker results are written and the Kubernetes identities that write them. | Keep `fss`; it keeps result delivery on a private shared filesystem and workers do not receive Object Storage credentials. Set File Storage Availability Domain when it should remain independent of future worker placement changes. |
| Benchmark profiles | Optional, dedicated pools for repeatable cross-shape comparisons. | Leave all choices off unless you plan to run `operator/run-benchmark.sh`. |
| Private operator workstation | The private VM reached through Bastion that builds images, operates the cluster, and aggregates results. | Keep the architecture-aware shape and sizing defaults. Set its Availability Domain explicitly when it should remain independent of future worker placement changes. |
| Operator identity and permissions | Whether the stack creates the IAM identity and policies used by the operator. | Keep the defaults unless these resources are managed by your platform team. |
| Advanced deployment settings | OCIR realm override, optional Vault key, and tags. | Leave empty unless your environment requires them. |

## Choose benchmark profiles without structured input

Select only the hardware you intend to compare. Each selection creates one dedicated OKE node pool with a profile label that `operator/run-benchmark.sh` uses for placement.

| Selection | Profile name used by the benchmark command | Architecture | Image to provide when the primary image cannot be reused |
|---|---|---|---|
| Add AMD E5 Flex pool | `e5-flex` | amd64 | AMD and Intel OKE image OCID |
| Add AMD E6 Flex pool | `e6-flex` | amd64 | AMD and Intel OKE image OCID |
| Add AMD E6 Acceleron pool | `e6-acceleron` | amd64 | AMD and Intel OKE image OCID |
| Add Intel Optimized3 Flex pool | `intel-optimized3` | amd64 | AMD and Intel OKE image OCID |
| Add Intel Acceleron pool | `intel-acceleron` | amd64 | AMD and Intel OKE image OCID |
| Add Ampere A4 Acceleron pool | `a4-acceleron` | arm64 | Ampere A4 OKE image OCID |

The primary worker image is reused automatically for selected profiles with the same architecture. For example, an amd64 primary worker image covers E5 Flex, E6 Flex, E6 Acceleron, Intel Optimized3, and Intel Acceleron; provide the Arm image only when adding A4 to that cluster. Every supplied image must match the selected Kubernetes version.

Set one shared capacity plan for all selected Flex profiles. This keeps comparisons controlled: each profile gets the same OCPU count, memory, initial Node count, and Pod limit. Enable benchmark-pool autoscaling only when you want to demonstrate elastic capacity; its minimum and maximum values apply to every selected benchmark pool.

## After the stack applies

Use the `operator_session_create_command` stack output to create a managed SSH session, connect as `opc`, and work from `/home/opc/oci-monte-carlo-quickstart`. The runtime sequence is:

```bash
./operator/preflight.sh
./operator/install-runtime.sh
./operator/build-and-push.sh
./operator/create-pull-secret.sh
./operator/run-example.sh
```

For a selected benchmark profile, run the insurance benchmark with its profile name:

```bash
./operator/run-benchmark.sh --profile-id e6-flex --architecture amd64
```

If you add or alter benchmark profile selections in a later stack update, increment `operator_bootstrap_generation` in the same apply. This refreshes the private operator's local profile configuration to match the node pools.

`benchmark_node_pools_json` is retained for advanced Terraform CLI workflows that need a custom shape. It is deliberately absent from the Resource Manager form.
