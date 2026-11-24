# Security policy and deployment controls

## Intended security posture

This project is an accelerator, not a replacement for a customer's landing-zone controls. It assumes a dedicated compartment and deploys a private enhanced OKE cluster by default. It does not create public application load balancers, public Object Storage buckets, default passwords, or OCI API-key secrets.

## Controls implemented in code

- Private OKE API endpoint, worker nodes, pods, OCIR repository, Object Storage bucket, and operator workstation. OCI Bastion Managed SSH is the only interactive path.
- Default FSS result delivery: worker nodes and the operator reach a private mount target through restricted NSGs and export options. Worker clients are mapped to UID/GID `10001`; the simulator receives no service-account token for OCI result access. The application publishes each final name atomically. Treat the shared export as a node-level trust boundary, not a per-run credential or retention lock.
- Optional Object Storage result delivery: the worker uses OKE Workload Identity for the configured cluster, namespace and ServiceAccount. Its write policy is limited to the bucket and result prefix. The operator reads results with its own instance principal. No user API keys are placed in worker containers.
- Namespace labels that enforce the Kubernetes Pod Security `restricted` profile.
- Non-root workload, immutable root filesystem, dropped Linux capabilities, `RuntimeDefault` seccomp profile, explicit resource limits, and no privilege escalation.
- Namespace-wide default-deny ingress and egress NetworkPolicy. In FSS mode the simulator needs no Pod network egress for publishing; NFS runs from the worker node. In Object Storage mode the simulator policy allows DNS and TCP/443. Validate CNI enforcement and restrict destinations to approved endpoints where required.
- Image digest required by the Helm chart. Tags are not accepted for deployed jobs.
- Bootstrap bundle SHA-256 verification, verified single-stream Object Storage download, checksum-verified kubectl/Helm installation, and a visible operator bootstrap status record.
- Interactive OCIR auth-token prompts; tokens are not passed as environment variables, Terraform values, or shell arguments. The Kubernetes pull secret is created from a temporary Docker configuration.
- Structured logs omit input data and credentials.
- Synthetic sample data only.

## Controls the OCI Admin must own

- IAM policies for the human deployer and OCI Bastion session users, network route review, and OCI tenancy logging policy. Any user allowed to operate the VM can act through its instance principal, so restrict Bastion access, sudo, and Docker-group membership.
- Image vulnerability scanning, image-signing policy, and registry retention policy in the target tenancy.
- Security Zones, Cloud Guard, data classification, key-management, retention, backup, and incident-response policy.
- A formal review before using portfolio, customer, market, or regulated data, including an agreed OCIR pull-secret rotation process.
