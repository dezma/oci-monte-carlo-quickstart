variable "tenancy_ocid" {
  description = "OCID of the tenancy."
  type        = string
  nullable    = false
}

variable "compartment_ocid" {
  description = "Dedicated compartment in which to create quickstart resources."
  type        = string
  nullable    = false
}

variable "region" {
  description = "OCI region identifier, for example us-ashburn-1."
  type        = string
  nullable    = false
}

variable "name_prefix" {
  description = "Short lowercase resource prefix."
  type        = string
  default     = "mcqs"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.name_prefix))
    error_message = "name_prefix must start with a letter and contain 2-16 lowercase letters, digits, or hyphens."
  }
}

variable "availability_domain" {
  description = "Optional Availability Domain name. Null selects the first available domain."
  type        = string
  default     = null
  nullable    = true
}

variable "kubernetes_version" {
  description = "Full OKE patch version selected from the live OKE version list. Defaults to v1.36.1."
  type        = string
  default     = "v1.36.1"
  nullable    = false

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", trimspace(var.kubernetes_version)))
    error_message = "kubernetes_version is required and must be a full OKE patch version, including the v prefix, returned by provisioning/list-oke-options.sh (for example v1.36.1)."
  }
}

variable "node_architecture" {
  description = "CPU architecture of the selected OKE worker image. This explicitly configures the operator's native image build and job default; it is not inferred from node_shape."
  type        = string
  default     = "amd64"
  nullable    = false

  validation {
    condition     = contains(["amd64", "arm64"], trimspace(var.node_architecture))
    error_message = "node_architecture must be amd64 or arm64."
  }
}

variable "vcn_cidr" {
  description = "CIDR for the isolated quickstart VCN."
  type        = string
  default     = "10.42.0.0/16"
}

variable "api_subnet_cidr" {
  description = "Private subnet CIDR for the Kubernetes API endpoint."
  type        = string
  default     = "10.42.0.0/28"
}

variable "worker_subnet_cidr" {
  description = "Private subnet CIDR for OKE worker nodes."
  type        = string
  default     = "10.42.1.0/24"
}

variable "pod_subnet_cidr" {
  description = "Private subnet CIDR for VCN-native pods."
  type        = string
  default     = "10.42.16.0/20"
}

variable "service_lb_subnet_cidr" {
  description = "Private subnet CIDR reserved for internal Kubernetes load balancers."
  type        = string
  default     = "10.42.32.0/24"
}

variable "operator_subnet_cidr" {
  description = "Dedicated private subnet CIDR for the operator instance. This is the only subnet allowed to reach the private OKE API."
  type        = string
  default     = "10.42.48.0/28"
}

variable "bastion_subnet_cidr" {
  description = "Dedicated private subnet CIDR for OCI Bastion service endpoints. Must not overlap any other subnet."
  type        = string
  default     = "10.42.49.0/28"
}

variable "bastion_client_cidr" {
  description = "Required public client CIDR allowed to create OCI Bastion sessions, normally a corporate VPN range or a single workstation /32. This is not a Cloud Shell CIDR."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrhost(var.bastion_client_cidr, 0))
    error_message = "bastion_client_cidr must be a valid IPv4 or IPv6 CIDR, such as 203.0.113.25/32."
  }
}

variable "node_shape" {
  description = "Any OKE-supported OCI Compute shape available in the chosen Availability Domain. Use provisioning/list-shapes.sh to discover values."
  type        = string
  default     = "VM.Standard.E6.Flex"
}

variable "node_shape_ocpus" {
  description = "OCPUs per node for flex shapes. Ignored for fixed shapes."
  type        = number
  default     = 2
  nullable    = true
}

variable "node_shape_memory_gbs" {
  description = "Memory in GB per node for flex shapes. Ignored for fixed shapes."
  type        = number
  default     = 16
  nullable    = true
}

variable "node_pool_size" {
  description = "Initial managed worker node count."
  type        = number
  default     = 2

  validation {
    condition     = var.node_pool_size >= 1 && var.node_pool_size <= 100
    error_message = "node_pool_size must be between 1 and 100."
  }
}

variable "max_pods_per_node" {
  description = "Maximum VCN-native pods per node. Validate this against the selected shape's VNIC capacity."
  type        = number
  default     = 31
}

variable "node_image_id" {
  description = "Required OKE-compatible node image OCID. Discover it for the selected Kubernetes version and node architecture before provisioning."
  type        = string
  nullable    = false

  validation {
    condition     = startswith(var.node_image_id, "ocid1.image.")
    error_message = "node_image_id is required and must be an OCI image OCID (ocid1.image...)."
  }
}

variable "operator_shape" {
  description = "Optional Flex Compute shape override for the private operator workstation. Null selects VM.Standard.A4.Flex for arm64 worker targets and VM.Standard.E5.Flex for amd64 worker targets."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.operator_shape == null || try(endswith(var.operator_shape, "Flex"), false)
    error_message = "operator_shape must be a flexible VM shape because this quickstart sets explicit OCPUs and memory."
  }
}

variable "operator_shape_ocpus" {
  description = "OCPUs for the operator workstation."
  type        = number
  default     = 1
}

variable "operator_shape_memory_gbs" {
  description = "Memory in GB for the operator workstation."
  type        = number
  default     = 8
}

variable "operator_boot_volume_gbs" {
  description = "Boot volume size in GB for the operator workstation."
  type        = number
  default     = 50
}

variable "operator_image_id" {
  description = "Optional custom operator image OCID. Leave null to select the newest Oracle Linux 8 platform image compatible with the resolved operator shape and architecture."
  type        = string
  default     = null
  nullable    = true
}

variable "operator_helm_version" {
  description = "Pinned Helm version installed on the operator instance."
  type        = string
  default     = "v3.17.3"
}

variable "kubernetes_namespace" {
  description = "Namespace reserved for the quickstart workload."
  type        = string
  default     = "monte-carlo"
}

variable "service_account_name" {
  description = "Service account used by the batch jobs."
  type        = string
  default     = "monte-carlo-runner"
}

variable "object_storage_bucket_name" {
  description = "Optional globally-unique Object Storage bucket name. Null derives a tenancy-safe name from the prefix."
  type        = string
  default     = null
  nullable    = true
}

variable "object_storage_prefix" {
  description = "Object name prefix that the workload identity may write beneath."
  type        = string
  default     = "monte-carlo"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", var.object_storage_prefix)) && !endswith(var.object_storage_prefix, "/")
    error_message = "object_storage_prefix must be a non-empty path-like prefix without a trailing slash."
  }
}

variable "ocir_registry" {
  description = "Optional OCIR registry domain. Null derives <region-key>.ocir.io from the tenancy's current region subscription. Set this for a realm-specific registry endpoint."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.ocir_registry == null || can(regex("^[A-Za-z0-9.-]+$", var.ocir_registry))
    error_message = "ocir_registry must be a registry domain only, with no scheme or path."
  }
}

variable "kms_key_id" {
  description = "Optional existing OCI Vault key OCID for customer-managed Object Storage encryption."
  type        = string
  default     = null
  nullable    = true
}

variable "freeform_tags" {
  description = "Additional freeform tags applied to created resources."
  type        = map(string)
  default     = {}
}
