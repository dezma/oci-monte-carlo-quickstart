data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

locals {
  availability_domain = coalesce(var.availability_domain, data.oci_identity_availability_domains.this.availability_domains[0].name)
  kubernetes_version  = trimspace(var.kubernetes_version)
  node_architecture   = trimspace(var.node_architecture)
  operator_shape      = coalesce(var.operator_shape, local.node_architecture == "arm64" ? "VM.Standard.A4.Flex" : "VM.Standard.E5.Flex")
  resource_prefix     = substr(replace(var.name_prefix, "-", ""), 0, 12)
  bucket_name         = coalesce(var.object_storage_bucket_name, "${local.resource_prefix}-monte-carlo-results")
  ocir_region_key = lower(one([
    for subscription in data.oci_identity_region_subscriptions.this.region_subscriptions : subscription.region_key
    if subscription.region_name == var.region
  ]))
  ocir_registry            = coalesce(var.ocir_registry, "${local.ocir_region_key}.ocir.io")
  container_repository_url = "${local.ocir_registry}/${oci_artifacts_container_repository.monte_carlo.namespace}/${oci_artifacts_container_repository.monte_carlo.display_name}"
  operator_bundle_path     = "${path.module}/operator/payload/monte-carlo-quickstart.tar.gz"
  operator_bundle_sha256   = filesha256(local.operator_bundle_path)
  operator_bundle_name     = "bootstrap/monte-carlo-quickstart-${substr(local.operator_bundle_sha256, 0, 16)}.tar.gz"
  operator_kubectl_version = startswith(local.kubernetes_version, "v") ? local.kubernetes_version : "v${local.kubernetes_version}"
  tags = merge(
    {
      Project     = "oci-monte-carlo-quickstart"
      ManagedBy   = "terraform"
      Environment = "quickstart"
    },
    var.freeform_tags,
  )
}
