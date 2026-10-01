resource "oci_identity_policy" "workload_object_storage" {
  compartment_id = var.compartment_ocid
  name           = "${local.resource_prefix}-monte-carlo-workload"
  description    = "Least-privilege Object Storage access for the Monte Carlo OKE workload identity."
  freeform_tags  = local.tags

  statements = [
    "Allow any-user to manage objects in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.namespace = '${var.kubernetes_namespace}', request.principal.service_account = '${var.service_account_name}', request.principal.cluster_id = '${oci_containerengine_cluster.this.id}', target.bucket.name = '${oci_objectstorage_bucket.results.name}', target.object.name = '${var.object_storage_prefix}/runs/*', request.permission = 'OBJECT_CREATE'}",
  ]
}

resource "oci_identity_dynamic_group" "operator" {
  compartment_id = var.tenancy_ocid
  name           = "${local.resource_prefix}-mcqs-operator"
  description    = "Instance-principal identity for the private Monte Carlo operator workstation."
  matching_rule  = "ALL {instance.id = '${oci_core_instance.operator.id}'}"
}

resource "oci_identity_policy" "operator" {
  compartment_id = var.compartment_ocid
  name           = "${local.resource_prefix}-mcqs-operator"
  description    = "Least-privilege OKE and Object Storage access for the private operator workstation."
  freeform_tags  = local.tags

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.operator.name} to use clusters in compartment id ${var.compartment_ocid} where target.cluster.id = '${oci_containerengine_cluster.this.id}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.operator.name} to read objects in compartment id ${var.compartment_ocid} where all {target.bucket.name = '${oci_objectstorage_bucket.results.name}', target.object.name = '${local.operator_bundle_name}'}",
    "Allow dynamic-group ${oci_identity_dynamic_group.operator.name} to read objects in compartment id ${var.compartment_ocid} where all {target.bucket.name = '${oci_objectstorage_bucket.results.name}', target.object.name = '${var.object_storage_prefix}/runs/*'}",
  ]
}
