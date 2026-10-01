# Threat model and security review prompts

## Assets

- Simulation inputs, model parameters, and any regulated portfolio data.
- Partial and aggregate simulation results.
- OCI infrastructure state, image manifests, and Kubernetes configuration.
- The ability to run or alter simulations.

## Primary threats and controls

| Threat | Design control | Customer decision required |
|---|---|---|
| Public control-plane or workload exposure | Private endpoint and subnets; no public service in the chart; private operator reached only through time-limited Bastion sessions | Set the narrow Bastion client CIDR and review session use. |
| Operator credential theft | Operator uses an instance principal; no user API key, private key, or OCIR token is injected by Terraform | Review dynamic-group policy, bootstrap object access, OS patching, and auth-token rotation. |
| Credential theft from a pod | OKE Workload Identity; no OCI config/API key in image; write-only Object Storage access is scoped to one bucket and result prefix | Review workload IAM policy and the separately rotated OCIR pull secret. |
| OCIR pull access confused with operator access | The Bastion-reached operator uses an instance principal for OCI control-plane access, while Kubernetes uses a namespace-scoped `ocir-pull` secret for private image pulls | Keep the pull credential out of Terraform, source control, and shell history; rotate it before expiry. |
| Privilege escalation in Kubernetes | Restricted Pod Security, non-root user, no privilege escalation/capabilities, read-only root | Enforce compatible admission policy across the cluster. |
| Lateral pod movement | Namespace isolation and default-deny ingress/controlled egress policy | Validate CNI policy enforcement and additional namespace rules. |
| Image tampering | Digest-only deployment and build provenance/SBOM generation | Configure OCI Registry vulnerability scanning and signed-image admission policy. |
| Result tampering or mix-up | Input hash, run ID, partition metadata, conditional write-once partial objects, and an `OBJECT_CREATE`-only IAM policy | Set bucket retention, customer-managed encryption, and result retention policy. |
| Unbounded cloud cost | Explicit node/pod resource limits, job deadline, TTL, pre-apply plan | Set budgets, quotas, and a project-specific maximum parallelism. |

## Production review checklist

- Is the compartment inside a Security Zone or monitored by Cloud Guard?
- Are Object Storage bucket retention and customer-managed encryption required?
- Does the IAM policy remain limited to the one result bucket/prefix, with only `OBJECT_CREATE` available to the runtime?
- Has OCI Registry image signing and vulnerability scanning been enforced before deployment?
- Does the production cluster enforce Pod Security Admission, RBAC, NetworkPolicy, and audit logging?
- Is the Bastion client CIDR narrow, are sessions time-limited, and is operator dynamic-group access reviewed separately from the workload policy?
