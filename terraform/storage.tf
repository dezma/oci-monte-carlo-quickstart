data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "results" {
  compartment_id        = var.compartment_ocid
  namespace             = data.oci_objectstorage_namespace.this.namespace
  name                  = local.bucket_name
  access_type           = "NoPublicAccess"
  versioning            = "Enabled"
  object_events_enabled = false
  auto_tiering          = "Disabled"
  kms_key_id            = var.kms_key_id
  freeform_tags         = local.tags
}

resource "oci_artifacts_container_repository" "monte_carlo" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}/monte-carlo"
  is_public      = false
  freeform_tags  = local.tags
}

resource "oci_objectstorage_object" "operator_bundle" {
  bucket       = oci_objectstorage_bucket.results.name
  namespace    = data.oci_objectstorage_namespace.this.namespace
  object       = local.operator_bundle_name
  source       = local.operator_bundle_path
  content_type = "application/gzip"
}
