resource "oci_identity_policy" "workload_object_storage" {
  count = local.object_storage_result_delivery && var.create_workload_object_storage_policy ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${local.resource_prefix}-monte-carlo-workload"
  description    = "Least-privilege Object Storage access for the Monte Carlo OKE workload identity."
  freeform_tags  = local.tags

  statements = [
    "Allow any-user to manage objects in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = '${var.kubernetes_namespace}', request.principal.service_account = '${var.service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}', target.bucket.name = '${oci_objectstorage_bucket.results.name}', target.object.name = '${var.object_storage_prefix}/runs/*', request.permission = 'OBJECT_CREATE'}",
  ]
}

resource "oci_identity_dynamic_group" "operator" {
  count = var.create_operator_dynamic_group ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = local.operator_dynamic_group_name
  description    = "Instance-principal identity for the private Monte Carlo operator workstation."
  matching_rule  = "ALL {instance.id = '${oci_core_instance.operator.id}'}"
}

resource "terraform_data" "operator_identity_configuration" {
  input = {
    create_dynamic_group = var.create_operator_dynamic_group
    dynamic_group_ocid   = var.operator_dynamic_group_ocid
    access_mode          = local.operator_kubernetes_access_mode
  }

  lifecycle {
    precondition {
      condition     = !local.operator_identity_is_referenced || var.create_operator_dynamic_group || var.operator_dynamic_group_ocid != null
      error_message = "operator_dynamic_group_ocid is required when an externally managed operator dynamic group is referenced by a selected policy or namespace_rbac mode."
    }

    precondition {
      condition     = !var.create_operator_dynamic_group || var.operator_dynamic_group_ocid == null
      error_message = "Set operator_dynamic_group_ocid only when create_operator_dynamic_group is false."
    }
  }
}

resource "oci_identity_policy" "operator_cluster_access" {
  count = var.create_operator_cluster_access_policy ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${local.resource_prefix}-mcqs-operator-cluster"
  description    = "Scoped OKE cluster access for the private operator workstation."
  freeform_tags  = local.tags

  statements = [
    "Allow dynamic-group id ${local.operator_dynamic_group_ocid} to ${local.operator_cluster_verb} clusters in compartment id ${var.compartment_ocid} where target.cluster.id = '${oci_containerengine_cluster.this.id}'",
  ]

  depends_on = [terraform_data.operator_identity_configuration]
}

resource "oci_identity_policy" "operator_bootstrap_bundle_read" {
  count = var.create_operator_bootstrap_bundle_read_policy ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${local.resource_prefix}-mcqs-operator-bootstrap"
  description    = "Scoped Object Storage read access for the private operator bootstrap bundle."
  freeform_tags  = local.tags

  statements = [
    "Allow dynamic-group id ${local.operator_dynamic_group_ocid} to read objects in compartment id ${var.compartment_ocid} where all {target.bucket.name = '${oci_objectstorage_bucket.results.name}', target.object.name = '${local.operator_bundle_name}'}",
  ]

  depends_on = [terraform_data.operator_identity_configuration]
}

resource "oci_identity_policy" "operator_results_read" {
  count = local.object_storage_result_delivery && var.create_operator_results_read_policy ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${local.resource_prefix}-mcqs-operator-results"
  description    = "Scoped Object Storage read access for private operator result aggregation."
  freeform_tags  = local.tags

  statements = [
    "Allow dynamic-group id ${local.operator_dynamic_group_ocid} to read objects in compartment id ${var.compartment_ocid} where all {target.bucket.name = '${oci_objectstorage_bucket.results.name}', target.object.name = '${var.object_storage_prefix}/runs/*'}",
  ]

  depends_on = [terraform_data.operator_identity_configuration]
}

# OCI Cluster Autoscaler uses an OKE workload identity. OCI policy grammar
# represents this subject as any-user and then narrows it to this cluster's
# kube-system/cluster-autoscaler workload before granting the listed actions.
resource "oci_identity_policy" "benchmark_cluster_autoscaler_workload_identity" {
  count = local.benchmark_cluster_autoscaler_enabled && var.create_benchmark_cluster_autoscaler_workload_identity_policy ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${local.resource_prefix}-mcqs-benchmark-ca"
  description    = "Condition-scoped OKE Cluster Autoscaler workload identity access for benchmark node pools."
  freeform_tags  = local.tags

  statements = [
    "Allow any-user to manage cluster-node-pools in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = 'kube-system', request.principal.service_account = 'cluster-autoscaler', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to manage instance-family in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = 'kube-system', request.principal.service_account = 'cluster-autoscaler', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to use subnets in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = 'kube-system', request.principal.service_account = 'cluster-autoscaler', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to read virtual-network-family in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = 'kube-system', request.principal.service_account = 'cluster-autoscaler', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to use vnics in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = 'kube-system', request.principal.service_account = 'cluster-autoscaler', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
    "Allow any-user to inspect compartments in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = 'kube-system', request.principal.service_account = 'cluster-autoscaler', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}'}",
  ]
}
