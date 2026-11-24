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

output "cluster_private_api_ip" {
  value       = local.cluster_private_api_ip
  description = "IP address portion of the private Kubernetes API endpoint, for OCI Bastion port-forwarding sessions."
}

output "cluster_private_api_port" {
  value       = local.cluster_private_api_port
  description = "TCP port portion of the private Kubernetes API endpoint, for OCI Bastion port-forwarding sessions."
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

output "bastion_session_ttl_seconds" {
  value       = var.bastion_session_ttl_seconds
  description = "Maximum lifetime used by the generated Bastion session commands."
}

output "operator_session_create_command" {
  value       = "oci bastion session create-managed-ssh --bastion-id ${oci_bastion_bastion.operator.id} --target-resource-id ${oci_core_instance.operator.id} --target-os-username opc --target-port 22 --ssh-public-key-file ${var.bastion_ssh_public_key_file} --session-ttl ${var.bastion_session_ttl_seconds} --wait-for-state SUCCEEDED"
  description = "Run from a workstation with OCI CLI and an SSH key. Then copy the SSH command from the Bastion session details."
}

output "operator_rbac_bastion_session_create_command" {
  value       = "oci bastion session create-port-forwarding --bastion-id ${oci_bastion_bastion.operator.id} --target-private-ip ${local.cluster_private_api_ip} --target-port ${local.cluster_private_api_port} --ssh-public-key-file ${var.bastion_ssh_public_key_file} --session-ttl ${var.bastion_session_ttl_seconds} --wait-for-state SUCCEEDED"
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

output "worker_availability_domain" {
  value       = local.availability_domain
  description = "Availability Domain used by the primary and benchmark OKE worker node pools."
}

output "worker_subnet_id" {
  value       = oci_core_subnet.worker.id
  description = "Private OKE worker subnet OCID."
}

output "pod_subnet_id" {
  value       = oci_core_subnet.pod.id
  description = "Private VCN-native OKE pod subnet OCID."
}

output "oke_internal_nsg_id" {
  value       = oci_core_network_security_group.oke_internal.id
  description = "Network security group OCID used by the private OKE control plane, workers, and pods."
}

output "fss_worker_client_nsg_id" {
  value       = try(oci_core_network_security_group.fss_worker_client[0].id, null)
  description = "FSS worker-client network security group OCID when FSS result delivery is selected."
}

output "operator_availability_domain" {
  value       = local.operator_availability_domain
  description = "Availability Domain used by the private operator VM."
}

output "fss_availability_domain" {
  value       = local.fss_enabled ? local.fss_availability_domain : null
  description = "Availability Domain used by OCI File Storage resources when FSS result delivery is selected."
}

output "benchmark_node_pool_ids" {
  value       = { for profile_id, pool in oci_containerengine_node_pool.benchmark : profile_id => pool.id }
  description = "Dedicated Terraform-managed benchmark node pool OCIDs by profile ID."
}

output "benchmark_node_pool_profiles" {
  value = {
    for profile_id, profile in local.benchmark_node_pools : profile_id => {
      node_shape   = profile.node_shape
      architecture = profile.architecture
      initial_size = profile.initial_size
      min_size     = profile.min_size
      max_size     = profile.max_size
      node_selector = "${local.benchmark_profile_label_key}=${profile_id}"
      taint         = "${local.benchmark_profile_taint_key}=${profile_id}:${local.benchmark_profile_taint_effect}"
    }
  }
  description = "Benchmark profile placement, taint, and capacity settings rendered from guided profile selections or advanced Terraform CLI configuration."
}

output "benchmark_cluster_autoscaler_enabled" {
  value       = local.benchmark_cluster_autoscaler_enabled
  description = "Whether this stack installs the OKE Cluster Autoscaler add-on for dedicated benchmark node pools."
}

output "benchmark_cluster_autoscaler_workload_identity_policy_created" {
  value       = local.benchmark_cluster_autoscaler_enabled && var.create_benchmark_cluster_autoscaler_workload_identity_policy
  description = "Whether this stack creates the condition-scoped Cluster Autoscaler workload identity policy."
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
  value       = local.operator_dynamic_group_ocid
  description = "Dynamic group OCID used for the private operator instance principal."
}

output "operator_namespace_rbac_manifest" {
  value = local.operator_kubernetes_access_mode == "namespace_rbac" ? templatefile("${path.module}/operator/namespace-rbac.yaml.tftpl", {
    kubernetes_namespace        = var.kubernetes_namespace
    operator_dynamic_group_ocid = local.operator_dynamic_group_ocid
  }) : null
  description = "Apply once as a cluster administrator through an OCI Bastion port-forwarding session when operator_kubernetes_access_mode is namespace_rbac."
}

output "object_storage_bucket" {
  value       = oci_objectstorage_bucket.results.name
  description = "Private bootstrap-bundle bucket and the result bucket when Object Storage result delivery is selected."
}

output "object_storage_namespace" {
  value       = data.oci_objectstorage_namespace.this.namespace
  description = "Object Storage namespace."
}

output "object_storage_prefix" {
  value       = var.object_storage_prefix
  description = "Result prefix used when Object Storage result delivery is selected."
}

output "workload_object_storage_policy_created" {
  value       = local.object_storage_result_delivery && var.create_workload_object_storage_policy
  description = "Whether this stack created the simulation-job Object Storage access policy. FSS result delivery does not create this policy."
}

output "operator_dynamic_group_created" {
  value       = var.create_operator_dynamic_group
  description = "Whether this stack created the private operator dynamic group."
}

output "operator_cluster_access_policy_created" {
  value       = var.create_operator_cluster_access_policy
  description = "Whether this stack created the private operator OKE cluster access policy."
}

output "operator_bootstrap_bundle_read_policy_created" {
  value       = var.create_operator_bootstrap_bundle_read_policy
  description = "Whether this stack created the private operator bootstrap-bundle read policy."
}

output "operator_results_read_policy_created" {
  value       = local.object_storage_result_delivery && var.create_operator_results_read_policy
  description = "Whether this stack created the private operator results-read policy. FSS result delivery does not create this policy."
}

output "result_delivery_mode" {
  value       = local.result_delivery_mode
  description = "Configured immutable partial-result delivery target."
}

output "fss_file_system_id" {
  value       = try(oci_file_storage_file_system.results[0].id, null)
  description = "OCI File Storage file system OCID when result_delivery_mode is fss."
}

output "fss_mount_target_id" {
  value       = try(oci_file_storage_mount_target.results[0].id, null)
  description = "Private FSS mount target OCID when result_delivery_mode is fss."
}

output "fss_mount_target_ip" {
  value       = local.fss_enabled ? local.fss_mount_target_ip : null
  description = "Private mount target IP used by the operator and OKE FSS CSI driver when result_delivery_mode is fss."
}

output "fss_export_path" {
  value       = local.fss_enabled ? var.fss_export_path : null
  description = "NFS export path used for FSS result delivery."
}

output "fss_persistent_volume_name" {
  value       = local.fss_enabled ? local.fss_persistent_volume_name : null
  description = "Static Kubernetes PersistentVolume name created by the runtime baseline for FSS result delivery."
}

output "fss_persistent_volume_claim_name" {
  value       = local.fss_enabled ? local.fss_persistent_volume_claim_name : null
  description = "Namespace-scoped Kubernetes PersistentVolumeClaim name used by FSS result delivery."
}

output "container_repository_url" {
  value       = local.container_repository_url
  description = "Private OCIR repository URL for the multi-architecture image."
}

output "log_group_id" {
  value       = oci_logging_log_group.this.id
  description = "Log group for quickstart observability configuration."
}
