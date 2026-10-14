# OCI Monte Carlo Quickstart

Deploy and run a secure, repeatable Monte Carlo option-pricing example on OCI.

The quickstart creates a private OKE environment for the workers and a private operator VM for the person running the workload. It is designed to help a quant, developer, cloud engineer, or security reviewer reach the same clear outcome: a reproducible estimate, a confidence interval, and the evidence needed to understand what produced it.

## Start here

There are two places to work. Keeping them separate is intentional.

| Stage | Where you work | What you do |
|---|---|---|
| Provision infrastructure | OCI Cloud Shell, workstation, or CI | Discover live OCI choices, build the Resource Manager archive, and provision the private environment. |
| Run simulations | Private operator VM through OCI Bastion | Build and publish the image, configure the pull secret, submit jobs, and read results. |

Cloud Shell is optional. Resource Manager creates infrastructure only; it does not connect to the private Kubernetes API or submit workloads.

## What is deployed

- Private enhanced OKE cluster, private worker nodes, and VCN-native pod networking.
- Private Compute operator VM with OCI Bastion Managed SSH access; it has no public IP.
- Private OCIR repository and a private, versioned Object Storage result bucket.
- A Helm runtime baseline with a restricted Pod Security policy, NetworkPolicy, resource limits, and a baseline-owned ServiceAccount.
- Indexed Kubernetes Jobs that write immutable partial results with OKE Workload Identity.
- A local operator-side reducer that validates the partial results and calculates the final estimate.

## The Monte Carlo example

The supplied example prices a one-year **European call option**. It asks: *what is the value today of the right to buy an asset for 100 in one year, when the asset is currently 102?*

For each simulated market path, the engine evolves the price with geometric Brownian motion, calculates the payoff at expiry, and discounts it to today

It averages many discounted payoffs to estimate the option value. The sample uses 200,000 paths, 32 time steps, a fixed seed, and antithetic paths (each random shock is paired with its inverse) to reduce statistical noise without changing the financial model.

The input is [examples/sample-simulation.json](examples/sample-simulation.json). Its important fields are:

| Field | Meaning |
|---|---|
| `spot`, `strike` | Asset price today and option exercise price. |
| `risk_free_rate`, `dividend_yield` | Rates used for the price drift and discounting. |
| `volatility` | Assumed annualized uncertainty of the asset price. |
| `maturity_years` | Time to expiry. |
| `simulations` | Total number of paths. More paths normally narrow the confidence interval. |
| `steps` | Time slices in each simulated path. |
| `seed` | Makes a chosen execution layout repeatable. |

`--parallelism` divides the fixed total number of paths across Indexed Job partitions. It is a throughput control, not an accuracy control: use more `simulations` when you need a tighter estimate, and more parallelism when the cluster has capacity to finish the same work sooner.

## Read the result

`./operator/run-example.sh --parallelism 4` waits for the job and prints JSON similar to:

```json
{
  "price": 12.37215463741667,
  "confidence_interval": [12.290717037763079, 12.453592237070263],
  "confidence_level": 0.95,
  "standard_error": 0.04155055924375422,
  "simulations": 200000,
  "partitions": 4
}
```

- **`price`** is the estimated present value under the model assumptions, approximately **12.37** for the sample.
- **`confidence_interval`** is the sampling interval. A 95% interval means that, over many independent Monte Carlo experiments built the same way, 95% of those intervals would contain the model’s true expected value. It is not a 95% probability statement about tomorrow’s market price.
- **`standard_error`** measures Monte Carlo sampling uncertainty. Roughly speaking, doubling the number of simulations reduces it by about \(\sqrt{2}\), not by two.
- **`sample_standard_deviation`** describes payoff dispersion across the simulated paths. It is different from the input market volatility.
- **`simulations`** and **`partitions`** confirm the amount of work and the execution layout.
- **`input_sha256`** binds the displayed result to one canonical simulation input. The reducer accepts only one run ID, one input hash, and exactly one result from every expected partition.
- **`total_worker_seconds`** is the sum of worker compute time. It is useful for benchmarking; it is not elapsed wall-clock duration.

The output validates numerical uncertainty under this model. It does not validate market assumptions, liquidity, calibration, or suitability for a trading decision.

## Guided deployment

### 1. Choose a live-compatible OKE configuration

From the provisioning plane, clone the repository and query the target tenancy. OCI’s live response is the source of truth for shape capacity, OKE versions, and node images.

```bash
git clone <your-repository-url> oci-monte-carlo-quickstart
cd oci-monte-carlo-quickstart

./provisioning/list-shapes.sh --compartment-id "$COMPARTMENT_OCID"
./provisioning/list-oke-options.sh --compartment-id "$COMPARTMENT_OCID"
```

Select a **full Kubernetes patch version** from the returned list, then select a node image for the same version and architecture. Both `kubernetes_version` and `node_image_id` are required Resource Manager inputs; neither has a deployment default.

```bash
export NODE_SHAPE="VM.Standard.E6.Flex"
export KUBERNETES_VERSION="<full-version-returned-by-OCI>"
export NODE_ARCHITECTURE="amd64"

./provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --node-shape "$NODE_SHAPE" \
  --architecture "$NODE_ARCHITECTURE" \
  --kubernetes-version "$KUBERNETES_VERSION"

export NODE_IMAGE_ID="ocid1.image..."

./provisioning/validate-oke-selection.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --node-shape "$NODE_SHAPE" \
  --architecture "$NODE_ARCHITECTURE" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --node-image-id "$NODE_IMAGE_ID"
```

Use `amd64` for Intel and AMD workers, and `arm64` for Ampere workers. Do not reuse an image OCID across Kubernetes versions or architectures.

### 2. Provision with Resource Manager

Build the archive:

```bash
./provisioning/build-orm.sh
```

Upload `dist/orm.zip` to OCI Resource Manager and create a stack. In the form, provide the live-verified Kubernetes version, node image OCID, architecture, shape, and sizing. Also provide a narrow `bastion_client_cidr`: the public CIDR of the workstation or corporate VPN that will create the Bastion session. For a single fixed public IPv4 address, use `/32`.

For a first deployment, choose `operator_kubernetes_access_mode = iam_admin`. It grants the operator OKE administration scoped to this quickstart cluster, so it can use Helm and kubectl. `namespace_rbac` is available for teams that want a separate administrator to apply the namespace-scoped binding once.

When the stack completes, create a Managed SSH session using the `operator_session_create_command` stack output. If needed, create an SSH key first:

```bash
mkdir -p ~/.ssh
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

Connect to the resulting Bastion session as `opc`.

### 3. Prepare the runtime on the private operator

Run these commands on the operator VM:

```bash
cd /home/opc/oci-monte-carlo-quickstart
source /etc/profile.d/mcqs-runtime.sh

./operator/doctor.sh
./operator/install-runtime.sh

# Use the OCI Console Profile-menu value, without the tenancy namespace.
# Federated example: oracleidentitycloudservice/your.name@example.com
export OCI_USER_NAME="<username-or-identity-domain/username>"

# Each command uses Docker's hidden password prompt for an OCIR auth token.
./operator/build-and-push.sh
./operator/create-pull-secret.sh
```

The default build follows the selected node architecture. Use `--multi-arch` only when you deliberately need one manifest for both `amd64` and `arm64`.

### 4. Run and review the sample

```bash
./operator/run-example.sh --parallelism 4
./operator/status.sh
```

The script creates a unique run, waits for all partitions, and prints the aggregate automatically. To review a completed run again with a different confidence level:

```bash
./operator/aggregate-results.sh \
  --run-id '<completed-run-id>' \
  --expected-partitions 4 \
  --confidence 0.95
```

## Select a deployment profile

Start with E6 Flex. The other profiles are useful for an intentional architecture or Acceleron benchmark. Always confirm every shape in your target availability domain immediately before deployment.

| Profile | Node shape | Architecture | Use it when |
|---|---|---|---|
| [starter-amd.tfvars](profiles/starter-amd.tfvars) | `VM.Standard.E6.Flex` | `amd64` | You want the standard onboarding path. |
| [amd-acceleron.tfvars](profiles/amd-acceleron.tfvars) | `VM.Standard.E6.Ax.Flex` | `amd64` | You are comparing current AMD Acceleron nodes. |
| [intel-acceleron.tfvars](profiles/intel-acceleron.tfvars) | `VM.Standard4.Ax.Flex` | `amd64` | You are comparing Intel Acceleron nodes. |
| [arm-a2.tfvars](profiles/arm-a2.tfvars) | `VM.Standard.A2.Flex` | `arm64` | You want a current non-Acceleron Ampere path. |
| [arm-acceleron.tfvars](profiles/arm-acceleron.tfvars) | `VM.Standard.A4.Ax.Flex` | `arm64` | You are benchmarking Ampere Acceleron nodes. |
| [hpc-amd.tfvars](profiles/hpc-amd.tfvars) | `BM.HPC.E5.144` | `amd64` | You have confirmed OKE support, capacity, and cost approval. |

Copy the relevant values into the Resource Manager form or a local `terraform.tfvars`; profiles do not replace the required live OKE version and image selection.

## Collateral guide

| Need | Read or run |
|---|---|
| Understand the trust boundaries and component flow | [Architecture](docs/architecture.md) |
| Follow the end-to-end provisioning and operator sequence | [Provisioning and operator guide](docs/provisioning-and-operator.md) |
| Run additional derivative products and a market-risk sensitivity grid | [Financial examples](docs/financial-examples.md) |
| Demonstrate Kueue scheduling, autoscaled capacity, and worker recovery | [Grid, elastic capacity, and resilience](docs/grid-elastic-resilience.md) |
| Select a current CPU, HPC, or Acceleron shape | [Shape catalogue](docs/shape-catalog.md) and `provisioning/list-shapes.sh` |
| Review security assumptions and residual risks | [Threat model](docs/threat-model.md) and [SECURITY.md](SECURITY.md) |
| Use local Terraform instead of Resource Manager | [Terraform guide](terraform/README.md) |
| Package the whole project for sharing | `./provisioning/package.sh` |

## Security and lifecycle

The quickstart uses private endpoints, a Bastion-only management route, instance principals for the operator, OKE Workload Identity for workers, a scoped result-write policy, digest-addressed images, and write-once partial results.

`./operator/cleanup-runtime.sh` removes Monte Carlo Helm releases while retaining the namespace and pull secret for deliberate rotation or review. Use a Resource Manager Destroy job to remove the full environment and stop billing. For local Terraform state, use `./provisioning/terraform-destroy.sh`.

## Development

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
helm lint helm/monte-carlo
```

## Licence

MIT. See [LICENSE](LICENSE).
