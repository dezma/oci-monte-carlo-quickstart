variable "auth" {
  description = "Optional OCI Terraform authentication method. Leave null for Resource Manager; use SecurityToken in Cloud Shell when required."
  type        = string
  default     = null
  nullable    = true
}

provider "oci" {
  region = var.region
  auth   = var.auth
}
