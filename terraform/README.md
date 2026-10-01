# Terraform deployment

This directory creates a new, isolated private environment. It provisions only infrastructure: a private enhanced OKE cluster, a managed OCI Bastion service, and a private operator workstation. The Helm workload is deliberately not deployed by Resource Manager.

## Required permissions

The deploying principal needs least-privilege permissions for the resources this stack creates in the target compartment: VCN, gateways, subnets, NSGs, OKE cluster/node pool, Object Storage bucket, OCIR repository, logging log group, and IAM policy. In a production tenancy, have the platform/IAM owner provide a reviewed policy rather than granting broad tenancy administrator access.

## Shape selection

Run these commands before creating the Resource Manager stack:

```bash
../provisioning/list-shapes.sh --compartment-id "$COMPARTMENT_OCID"
../provisioning/list-oke-options.sh --compartment-id "$COMPARTMENT_OCID"
../provisioning/list-oke-options.sh \
  --compartment-id "$COMPARTMENT_OCID" \
  --node-shape "VM.Standard.E6.Flex" \
  --architecture amd64 \
  --kubernetes-version v1.36.1
```

Set `node_shape` to an OKE-supported shape returned by OCI. Set `node_architecture` explicitly to `amd64` for Intel/AMD worker images or `arm64` for Ampere worker images; do not infer it from a shape name. For flex shapes, supply OCPUs and memory. For a fixed shape, set `node_shape_ocpus = null` and `node_shape_memory_gbs = null`.

Terraform defaults `kubernetes_version` to the full `v1.36.1` release, but the Resource Manager form still requires it to be reviewed and submitted. Select a compatible `node_image_id` for that exact version and the explicit `node_architecture`. Minor-only input such as `v1.36` is rejected before OCI is called; OKE accepts full patch versions only. The module installs the matching kubectl patch release. The module derives the normal OCIR registry domain from the tenancy's current region subscription. Set `ocir_registry` only when your OCI realm uses a different registry endpoint.

## Private operator management path

Terraform creates a private operator workstation in `operator_subnet_cidr` and permits only that subnet to reach the OKE API on TCP/6443. OCI Bastion uses the separate `bastion_subnet_cidr`; its managed SSH sessions are limited to the mandatory `bastion_client_cidr`. The operator has no public IP, uses an instance principal, and carries the generated kubeconfig and `operator/` plus `scripts/` runtime bundle. Its cluster permission is restricted to the cluster created by this stack.

Leave `operator_shape` unset for the architecture-aware default: `VM.Standard.A4.Flex` for an `arm64` node target and `VM.Standard.E5.Flex` for `amd64`. If A4 capacity is unavailable, override it with an Arm flexible shape returned by the live shape query. Any explicit override must be a flexible shape and use an image with the same CPU architecture. Bootstrap detects the actual operator architecture before downloading kubectl and Helm.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out quickstart.tfplan
terraform apply quickstart.tfplan
```

After the Apply job completes, create a Managed SSH session using the `operator_session_create_command` output. Connect as `opc`, then run the scripts from `/home/opc/oci-monte-carlo-quickstart`.
