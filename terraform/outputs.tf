output "cluster_id" {
  value       = oci_containerengine_cluster.this.id
  description = "Enhanced OKE cluster OCID."
}

output "region" {
  value       = var.region
  description = "OCI region used by the stack."
}

output "cluster_name" {
  value       = oci_containerengine_cluster.this.name
  description = "Enhanced OKE cluster name."
}

output "cluster_endpoint" {
  value       = oci_containerengine_cluster.this.endpoints[0].private_endpoint
  description = "Private Kubernetes API endpoint."
}

output "operator_instance_id" {
  value       = oci_core_instance.operator.id
  description = "Private operator workstation OCID. Create a Managed SSH Bastion session to this instance."
}

output "operator_private_ip" {
  value       = oci_core_instance.operator.private_ip
  description = "Private IP address of the operator workstation."
}

output "operator_user" {
  value       = "opc"
  description = "Linux user for OCI Bastion Managed SSH sessions."
}

output "operator_workspace" {
  value       = "/home/opc/oci-monte-carlo-quickstart"
  description = "Location of the quickstart scripts on the private operator instance."
}

output "bastion_id" {
  value       = oci_bastion_bastion.operator.id
  description = "OCI Bastion OCID used to reach the private operator workstation."
}

output "bastion_client_cidr" {
  value       = var.bastion_client_cidr
  description = "Public client CIDR permitted to create Bastion sessions."
}

output "operator_session_create_command" {
  value       = "oci bastion session create-managed-ssh --bastion-id ${oci_bastion_bastion.operator.id} --target-resource-id ${oci_core_instance.operator.id} --target-os-username opc --target-port 22 --ssh-public-key-file $HOME/.ssh/id_ed25519.pub --session-ttl 3600 --wait-for-state SUCCEEDED"
  description = "Run from a workstation with OCI CLI and an SSH key. Then copy the SSH command from the Bastion session details."
}

output "operator_rbac_bastion_session_create_command" {
  value       = "oci bastion session create-port-forwarding --bastion-id ${oci_bastion_bastion.operator.id} --target-private-ip ${oci_containerengine_cluster.this.endpoints[0].private_endpoint} --target-port 6443 --ssh-public-key-file $HOME/.ssh/id_ed25519.pub --session-ttl 3600 --wait-for-state SUCCEEDED"
  description = "Run only to apply operator_namespace_rbac_manifest as a tenancy administrator or Kubernetes cluster-admin. Then use the tunnel command displayed in the Bastion session details."
}

output "node_pool_id" {
  value       = oci_containerengine_node_pool.workers.id
  description = "Managed worker node pool OCID."
}

output "node_shape" {
  value       = var.node_shape
  description = "Configured worker node shape."
}

output "node_architecture" {
  value       = local.node_architecture
  description = "Configured OKE worker architecture used by the operator's native image build and Job selector."
}

output "operator_shape" {
  value       = local.operator_shape
  description = "Private operator VM shape selected for the configured worker architecture."
}

output "operator_kubernetes_access_mode" {
  value       = local.operator_kubernetes_access_mode
  description = "Kubernetes API authorization model selected for the operator instance."
}

output "operator_dynamic_group_id" {
  value       = oci_identity_dynamic_group.operator.id
  description = "Dynamic group OCID for the private operator instance principal."
}

output "operator_namespace_rbac_manifest" {
  value = templatefile("${path.module}/operator/namespace-rbac.yaml.tftpl", {
    kubernetes_namespace        = var.kubernetes_namespace
    operator_dynamic_group_ocid = oci_identity_dynamic_group.operator.id
  })
  description = "Apply once as a cluster administrator through an OCI Bastion port-forwarding session when operator_kubernetes_access_mode is namespace_rbac."
}

output "object_storage_bucket" {
  value       = oci_objectstorage_bucket.results.name
  description = "Private result bucket."
}

output "object_storage_namespace" {
  value       = data.oci_objectstorage_namespace.this.namespace
  description = "Object Storage namespace."
}

output "object_storage_prefix" {
  value       = var.object_storage_prefix
  description = "Write-only result prefix authorized for the workload identity."
}

output "container_repository_url" {
  value       = local.container_repository_url
  description = "Private OCIR repository URL for the multi-architecture image."
}

output "log_group_id" {
  value       = oci_logging_log_group.this.id
  description = "Log group for quickstart observability configuration."
}
