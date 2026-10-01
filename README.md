# OCI Monte Carlo Quickstart

A security-first, cloud-native quickstart for reproducible Monte Carlo option-pricing workloads on Oracle Cloud Infrastructure (OCI).

It deliberately separates two jobs that should not be confused:

| Plane | Where it runs | Responsibility |
|---|---|---|
| provisioning/ | Cloud Shell, a workstation, or CI | Discover live OKE choices, create the Resource Manager archive, and provision infrastructure. |
| operator/ | The private Compute instance reached through OCI Bastion | Connect to the private cluster, publish an image, create the pull secret, submit Jobs, and aggregate results. |

Cloud Shell is optional and is never the private-cluster operator. Resource Manager provisions infrastructure only; it does not attempt to run Helm or kubectl against the private OKE endpoint.

## What the quickstart deploys

- A private enhanced OKE cluster with private worker and VCN-native pod subnets.
- A private operator Compute instance and an OCI Bastion Managed SSH path.
- A private OCIR repository and private, versioned Object Storage bucket.
- A Helm baseline with restricted Pod Security labels, a baseline-owned ServiceAccount, resource limits, immutable digest-only jobs, and NetworkPolicy.
- Indexed Kubernetes Jobs that use OKE Workload Identity to create immutable partial results, followed by a local reducer that validates and aggregates them.

The default Kubernetes version is **v1.36.1**. It remains a visible, required Resource Manager field so the deployer confirms that this exact patch is offered in the target region and selects a matching node image. OKE requires a full patch version; **v1.36** alone is not a valid API value. **node_image_id** never has a default.

## Fast path: Resource Manager, Bastion, operator

From Cloud Shell or any OCI CLI workstation, clone the project and query live capacity. The OCI response—not a static document—is the source of truth for all shape families, including current Intel, AMD, Arm, GPU/HPC, and Acceleron offerings in the selected availability domain.

~~~bash
git clone <your-repository-url> oci-monte-carlo-quickstart
cd oci-monte-carlo-quickstart

./provisioning/list-shapes.sh --compartment-id "$COMPARTMENT_OCID"
./provisioning/list-oke-options.sh --compartment-id "$COMPARTMENT_OCID"
./provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --node-shape "VM.Standard.E6.Flex" \
  --architecture amd64 \
  --kubernetes-version v1.36.1

# Paste the image OCID selected above into this validation. It prevents an
# incompatible version/architecture/image combination from reaching Apply.
./provisioning/validate-oke-selection.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --node-shape "VM.Standard.E6.Flex" \
  --architecture amd64 \
  --kubernetes-version v1.36.1 \
  --node-image-id "ocid1.image..."

./provisioning/build-orm.sh
~~~

Upload dist/orm.zip to OCI Resource Manager and create a stack. In the form:

- Keep the prefilled **kubernetes_version = v1.36.1** only after the live check confirms it; otherwise choose another full version from the list.
- Enter the exact **node_image_id** returned for that version and architecture.
- Set **node_architecture** to **amd64** for Intel/AMD shapes such as VM.Standard.E6.Flex, or **arm64** for Arm shapes. It must match the selected image.
- Set **bastion_client_cidr** to the public CIDR of the workstation or corporate VPN that will create the Bastion session (for one fixed public IPv4 address, use /32). It is not a Cloud Shell CIDR.
- Leave **operator_shape** empty for the matching default (E5 Flex for amd64, A4 Flex for arm64). If the Arm default is unavailable in the selected availability domain, override it with an available Arm flexible shape returned by the live shape query.

Resource Manager shows the plan before Apply. When it completes, create a Managed SSH Bastion session from a workstation. If the output's example key file does not exist yet, create one first:

~~~bash
mkdir -p ~/.ssh
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
~~~

Run the **operator_session_create_command** stack output, then use the SSH command shown for the newly created Bastion session to connect as opc.

## Private operator workflow

All remaining commands run on the private operator instance:

~~~bash
cd /home/opc/oci-monte-carlo-quickstart
source /etc/profile.d/mcqs-runtime.sh

# Confirms bootstrap state, instance-principal access, and private OKE reachability.
./operator/doctor.sh

# The baseline owns the namespace and service account. Per-run releases reuse them.
./operator/install-runtime.sh

# Use the exact OCI Console Profile-menu form, without the tenancy namespace.
# Federated example: oracleidentitycloudservice/your.name@example.com
export OCI_USER_NAME="<username-or-identity-domain/username>"

# Both commands use Docker's hidden password prompt for the OCI auth token.
# No token is exported, written into the project, or put in a shell command.
./operator/build-and-push.sh
./operator/create-pull-secret.sh

# E6 Flex defaults to amd64 automatically through MCQS_NODE_ARCHITECTURE.
./operator/run-example.sh --parallelism 4
./operator/status.sh
~~~

run-example.sh waits for the Indexed Job and automatically prints the aggregate with its confidence interval. It caps quickstart parallelism at 32 by default; increase MCQS_MAX_PARALLELISM only after reviewing capacity and cost. For a completed run, re-run the reducer without resubmitting work:

~~~bash
./operator/aggregate-results.sh \
  --run-id '<completed-run-id>' \
  --expected-partitions 4 \
  --confidence 0.95
~~~

The default image build is native to the selected node architecture. This is the most reliable path for a single-family benchmark such as E6 Flex. Build a two-platform manifest only when it is actually needed:

~~~bash
./operator/build-and-push.sh --multi-arch
~~~

The script removes its temporary Docker login when it exits. This is intentional: a manual docker push afterward needs a new login, while the script itself performs the authenticated push before it logs out.

## Smooth-provisioning guardrails

- The bootstrap uses the Oracle Linux 8 package name python36-oci-cli.
- The private bundle download forces OCI CLI --no-multipart, runs under the opc instance-principal context, verifies the tar archive, and verifies its Terraform-provided SHA-256 before extraction.
- The selected full Kubernetes patch, such as v1.36.1, is used for the matching kubectl release with checksum verification. Helm checksum parsing is likewise explicit.
- The operator bundle excludes Terraform state, local credentials, test tooling, and local build artifacts. Its profile contains only the runtime identifiers needed to reach the private cluster and result bucket.
- The Image pull secret is created from a temporary Docker configuration and uses the documented OCIR auth-token flow. The workloads themselves never receive that token; they use OKE Workload Identity for Object Storage writes.
- Image metadata is stored as a repository and immutable SHA-256 digest only. A job chart rejects mutable image tags.
- The reducer uses Object Storage's start / next_start_with continuation model and validates run identity, input hash, and expected partition coverage before reporting a result.

If an older stack bootstrapped from a prior archive failed, rebuild and re-apply the current stack rather than hand-editing generated cloud-init on the instance. Start with operator/doctor.sh; it displays bootstrap state and validates private OKE connectivity.

## Shape and architecture choice

The project accepts any OKE-supported fixed or flexible Compute shape returned by provisioning/list-shapes.sh. It intentionally does not carry a stale hard-coded allowlist.

| Node type | Set node_architecture | Example |
|---|---:|---|
| Intel or AMD x86 shape | amd64 | VM.Standard.E6.Flex |
| Arm shape | arm64 | A supported Arm shape returned by OCI |

For flexible shapes, provide OCPUs and memory. For a fixed shape, set the flex values to null. Always query a node image with the exact OKE version and architecture, then run validate-oke-selection.sh before applying. See [shape guidance](docs/shape-catalog.md).

## Local Terraform alternative

Resource Manager is the recommended onboarding path. A platform team using local Terraform can instead create terraform/terraform.tfvars from the example and run:

~~~bash
./provisioning/terraform-apply.sh
~~~

That path uses local state. It produces the same private architecture. To tear it down, use provisioning/terraform-destroy.sh; for a Resource Manager stack, use a Resource Manager Destroy job.

## Architecture

~~~mermaid
flowchart TD
  P["Provisioning plane"] --> R["Resource Manager"]
  R --> O["Private OKE"]
  R --> B["OCI Bastion"]
  R --> W["Private operator VM"]
  B --> W
  W --> O
  O --> J["Indexed Jobs"]
  J --> S["Private Object Storage"]
~~~

The simulation engine prices European vanilla options with seeded, vectorized geometric-Brownian-motion paths and antithetic variates. Each partial contains the input hash, seed/partition, engine version, and timing information needed for a reproducible run.

## Repository map

~~~text
app/                 Python simulation engine and Object Storage reducer
docs/                architecture, threat model, human-centered guide, shape guide
examples/            synthetic sample input only
helm/monte-carlo/    baseline and immutable Indexed Job chart
operator/            private Bastion-reached operator commands
profiles/            example shape and sizing values
provisioning/        live discovery, validation, Resource Manager and local Terraform packaging
scripts/             shared shell helpers
terraform/           private OCI infrastructure and Resource Manager schema
tests/               deterministic unit tests
~~~

## Security and cleanup

Read [SECURITY.md](SECURITY.md) and the [threat model](docs/threat-model.md) before production use. The quickstart has private endpoints, a Bastion-only management route, a workload-scoped Object Storage policy, restricted pod controls, and immutable image/result handling. It is still an accelerator: production use should add reviewed IAM, image scanning/signing, retention, customer landing-zone controls, monitoring/alerts, and a data-handling review.

Resources are billable. operator/cleanup-runtime.sh removes only Helm releases and retains the namespace and pull secret. Use the Resource Manager Destroy job (or provisioning/terraform-destroy.sh for local state) to release the full environment.

## Development

~~~bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
helm lint helm/monte-carlo
~~~

## Licence

MIT. See [LICENSE](LICENSE).
