resource "oci_logging_log_group" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-observability"
  description    = "Log group reserved for Monte Carlo quickstart operational telemetry."
  freeform_tags  = local.tags
}
