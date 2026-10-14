# Human-centered quickstart design

## Personas and success criteria

| Persona | Success moment | Design response |
|---|---|---|
| Quant or developer | Receives a trusted price and confidence interval | Synthetic input, one deterministic run, clear result JSON, no Kubernetes expertise required. |
| Cloud engineer | Can repeat and remove the environment safely | Terraform plan, copyable profiles, private-network preflight, explicit destroy path. |
| Security/platform owner | Can explain each trust boundary | Threat model, scoped workload policy, no default credentials, and visible acceptance checklist. |

## Golden path principles

1. Ask for the smallest useful set of decisions: compartment, region, Bastion client CIDR, live node shape, node architecture, node image, and scale profile.
2. Explain why a decision is needed at the point it appears. For example, the user selects a full Kubernetes patch from the live OKE response and pairs it with a node image from that same version and architecture.
3. Use progressive disclosure: starter, scale, and production profiles share code but do not overwhelm a first-time user.
4. Make irreversible or costly steps explicit. Terraform shows a plan; destroy requires a typed confirmation.
5. Make failure actionable. The provisioning plane reports live shape and OKE compatibility; the Bastion-reached operator's doctor check reports bootstrap, instance-principal, and private-API failures without suggesting a public workaround.

The provisioning plane can be a local OCI CLI environment or optional Cloud Shell. It packages and applies infrastructure only. The private operator VM is the clearly separate place for the runtime baseline, image publishing, pull secret, simulation, and aggregation actions.

## First-run acceptance test

An onboarding session is successful when a user can, in one guided session:

- select a verified available shape;
- select a live-supported full Kubernetes patch, compatible node image, and the corresponding `amd64` or `arm64` architecture;
- deploy an isolated private environment;
- pass the private operator bootstrap and doctor check;
- install the shared baseline and publish a native digest-addressed image;
- create or rotate the separate OCIR pull secret;
- run the synthetic sample with a chosen parallelism and matching architecture;
- see a price, confidence interval, input hash, and runtime metadata; and
- understand how to stop jobs and remove infrastructure.

Multi-architecture publishing is an optional advanced path for an environment that needs both CPU architectures; it is not a prerequisite for a first native run.
