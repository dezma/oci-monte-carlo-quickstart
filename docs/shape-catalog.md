# Compute shape catalogue and selection guide

## Do not use a static allowlist as the deployment gate

OCI shape availability changes by region, availability domain, tenancy capacity, service limit, and OKE support. Run this project command before every deployment:

```bash
./provisioning/list-shapes.sh --compartment-id "$COMPARTMENT_OCID"
```

It calls OCI `ListShapes` for the selected availability domain and reports every shape visible to the tenancy. That includes newly released and regional Acceleron variants without requiring a code release of this quickstart.

## Current CPU families covered by the project

The Terraform node pool accepts any OKE-supported fixed or flexible shape returned by OCI. The following table documents the current families relevant to CPU Monte Carlo workloads. Use the exact name returned by the live query.

| Processor family | Flexible VM shapes | Fixed/bare-metal examples | Monte Carlo use |
|---|---|---|---|
| Intel | `VM.Standard3.Flex`, `VM.Standard4.Ax.Flex`, `VM.Optimized3.Flex` | `BM.Standard3.64`, `BM.Standard4.Ax.120`, `BM.Optimized3.36` | General compute, high-frequency optimized work, or Intel Acceleron testing. |
| AMD | `VM.Standard.E4.Flex`, `VM.Standard.E5.Flex`, `VM.Standard.E6.Flex`, `VM.Standard.E6.Ax.Flex` | `BM.Standard.E4.128`, `BM.Standard.E5.192`, `BM.Standard.E6.256`, `BM.Standard.E6.Ax.192` | Default x86 path; use E6/E6.Ax for current-generation price/performance testing. |
| AMD DenseIO | `VM.DenseIO.E4.Flex`, `VM.DenseIO.E5.Flex`, `VM.DenseIO.E6.Ax.Flex` | `BM.DenseIO.E4.128`, `BM.DenseIO.E5.128`, `BM.DenseIO.E6.Ax.192` | Only when local NVMe materially helps data ingestion or result staging. |
| AMD HPC | — | `BM.HPC.E5.144` | High-throughput, tightly coupled HPC experiments; validate OKE capacity and cost first. |
| Ampere Arm | `VM.Standard.A1.Flex`, `VM.Standard.A2.Flex`, `VM.Standard.A4.Flex`, `VM.Standard.A4.Ax.Flex` | `BM.Standard.A1.160`, `BM.Standard.A4.48`, `BM.Standard.A4.Ax.48` | High-density Arm workers; use `--architecture arm64`. |

### Oracle Acceleron naming

Acceleron is not an AMD-only feature. The current OCI Acceleron generation spans:

| Marketing family | Canonical shape family to discover/select | Processor family |
|---|---|---|
| E6 Standard Acceleron | `VM.Standard.E6.Ax.Flex`, `BM.Standard.E6.Ax.192` | AMD EPYC Turin |
| E6 DenseIO Acceleron | `VM.DenseIO.E6.Ax.Flex`, `BM.DenseIO.E6.Ax.192` | AMD EPYC Turin |
| X12 Standard Acceleron | `VM.Standard4.Ax.Flex`, `BM.Standard4.Ax.120` | Intel Xeon 6 |
| A4 Standard Acceleron | `VM.Standard.A4.Ax.Flex`, `BM.Standard.A4.Ax.48` | Ampere AmpereOne M |

OCI documentation uses the `.Ax` names in its compute-shape table. Always use the shape string returned by `list-shapes.sh`; do not substitute a marketing label such as `X12` into Terraform.

## Specialty and GPU shapes

The discovery script reports VM, bare metal, DenseIO, HPC/optimized, and GPU shapes available to the tenancy. GPU shapes are not the baseline for this CPU-oriented European-vanilla example, but the node-pool variable does not prohibit them. Before using a GPU node pool, replace the CPU engine with a verified GPU implementation, add resource limits/tolerations, and complete a performance/cost benchmark.

## Profile selection

| Profile | Shape | Architecture | Intended use |
|---|---|---|---|
| `starter-amd.tfvars` | `VM.Standard.E6.Flex` | `amd64` | Lowest-risk x86 onboarding path. |
| `amd-acceleron.tfvars` | `VM.Standard.E6.Ax.Flex` | `amd64` | Current AMD Acceleron benchmark path. |
| `intel-acceleron.tfvars` | `VM.Standard4.Ax.Flex` | `amd64` | Current Intel/X12 Acceleron benchmark path. |
| `arm-acceleron.tfvars` | `VM.Standard.A4.Ax.Flex` | `arm64` | Current Ampere A4 Acceleron benchmark path. |
| `hpc-amd.tfvars` | `BM.HPC.E5.144` | `amd64` | Controlled high-scale exercise only. |

The current flexible-shape documentation lists OCPU/memory ranges. Do not assume a requested configuration is available: capacity and permissible shape configurations are validated during the OCI apply.

## Architecture selection at run time

Architecture is a required part of the live OKE selection, not an assumption made after provisioning. After selecting a live shape and OKE version, run `provisioning/list-oke-options.sh` with `--node-shape`, `--architecture`, and `--kubernetes-version`, then choose a node image returned for that exact architecture. `v1.36.1` is the prefilled recommended full version, but retain it only when the live OKE query reports that exact patch.

The default image path is a native build for the selected node architecture. Match the Job selector to that same architecture:

```bash
./operator/build-and-push.sh
./operator/run-example.sh --parallelism 8 --architecture amd64
./operator/run-example.sh --parallelism 8 --architecture arm64
```

Use `amd64` for Intel and AMD shapes and `arm64` for Ampere shapes. The chart never mixes architectures inside one run; benchmark each family using the same input, seed, parallelism, and engine digest. For a deliberately portable image, use `./operator/build-and-push.sh --multi-arch` only when the Buildx builder can publish both variants to OCIR. Both paths resolve an immutable digest; the runtime never deploys a mutable tag.
