# Security policy and deployment controls

## Intended security posture

This project is an accelerator, not a replacement for a customer's landing-zone controls. It assumes a dedicated compartment and deploys a private enhanced OKE cluster by default. It does not create public application load balancers, public Object Storage buckets, default passwords, or OCI API-key secrets.

## Controls implemented in code

- Private OKE API endpoint, worker nodes, pods, OCIR repository, Object Storage bucket, and operator workstation. OCI Bastion Managed SSH is the only interactive path.
- Network Security Groups separated for control-plane endpoint, workers, and pods.
- Enhanced OKE plus a workload-scoped IAM policy for the exact namespace, service account, cluster, result bucket, and write-only result prefix. The operator instance-principal policy is scoped to the created cluster and bootstrap/result objects. The application uses conditional create to prevent a partial result from being overwritten.
- Workload Identity in the application; no OCI user credentials in containers.
- Namespace labels that enforce the Kubernetes Pod Security `restricted` profile.
- Non-root workload, immutable root filesystem, dropped Linux capabilities, `RuntimeDefault` seccomp profile, explicit resource limits, and no privilege escalation.
- Namespace-wide default-deny ingress and egress NetworkPolicy. Only simulator pods receive DNS and TCP/443 egress; validate CNI enforcement and tighten this further to landing-zone-approved OCI endpoints where required.
- Image digest required by the Helm chart. Tags are not accepted for deployed jobs.
- Bootstrap bundle SHA-256 verification, verified single-stream Object Storage download, checksum-verified kubectl/Helm installation, and a visible operator bootstrap status record.
- Interactive OCIR auth-token prompts; tokens are not passed as environment variables, Terraform values, or shell arguments. The Kubernetes pull secret is created from a temporary Docker configuration.
- Structured logs omit input data and credentials.
- Synthetic sample data only.

## Controls the customer must own

- IAM policies for the human deployer and OCI Bastion session users, network route review, and OCI tenancy logging policy. Any user allowed to operate the VM can act through its instance principal, so restrict Bastion access, sudo, and Docker-group membership.
- Image vulnerability scanning, image-signing policy, and registry retention policy in the target tenancy.
- Security Zones, Cloud Guard, data classification, key-management, retention, backup, and incident-response policy.
- A formal review before using portfolio, customer, market, or regulated data, including an agreed OCIR pull-secret rotation process.

## Reporting a vulnerability

Do not file sensitive vulnerability details in a public issue. Follow your organization's security-reporting procedure, include the project version and a minimal reproduction, and rotate any exposed credentials immediately.
