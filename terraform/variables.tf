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
  description = "Optional Availability Domain for OKE worker node pools. Null selects the first available domain. Set this when worker-shape capacity requires a specific placement."
  type        = string
  default     = null
  nullable    = true
}

variable "operator_availability_domain" {
  description = "Optional Availability Domain for the private operator VM. When omitted, the stack retains the operator placement selected at initial deployment even if worker nodes later move for capacity."
  type        = string
  default     = null
  nullable    = true
}

variable "fss_availability_domain" {
  description = "Optional Availability Domain for OCI File Storage resources when result_delivery_mode is fss. When omitted, the stack retains the FSS placement selected at initial deployment even if worker nodes later move for capacity."
  type        = string
  default     = null
  nullable    = true
}

variable "kubernetes_version" {
  description = "Required full OKE patch version selected from the live OKE version list."
  type        = string
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

variable "fss_subnet_cidr" {
  description = "Dedicated private subnet CIDR for the OCI File Storage mount target when result_delivery_mode is fss. Leave it non-overlapping with every other quickstart subnet."
  type        = string
  default     = "10.42.50.0/28"
  nullable    = false

  validation {
    condition     = can(cidrhost(var.fss_subnet_cidr, 10))
    error_message = "fss_subnet_cidr must be a CIDR with at least eleven usable addresses; use /28 or larger for an FSS mount target."
  }
}

variable "fss_mount_target_ip" {
  description = "Optional fixed private IPv4 address for the FSS mount target. Null selects host address 10 in fss_subnet_cidr."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.fss_mount_target_ip == null || can(cidrhost("${var.fss_mount_target_ip}/32", 0))
    error_message = "fss_mount_target_ip must be a valid IPv4 address when set."
  }
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

variable "bastion_session_ttl_seconds" {
  description = "Maximum lifetime in seconds for OCI Bastion sessions created for this environment. OCI Bastion permits 1,800 to 10,800 seconds; the default is the three-hour maximum."
  type        = number
  default     = 10800
  nullable    = false

  validation {
    condition     = var.bastion_session_ttl_seconds >= 1800 && var.bastion_session_ttl_seconds <= 10800 && floor(var.bastion_session_ttl_seconds) == var.bastion_session_ttl_seconds
    error_message = "bastion_session_ttl_seconds must be a whole number from 1800 (30 minutes) through 10800 (3 hours)."
  }
}

variable "bastion_ssh_public_key_file" {
  description = "Path to the RSA public key file on the workstation that will create Bastion sessions. This path is placed in the generated commands and is not read by Terraform."
  type        = string
  default     = "$HOME/.ssh/id_rsa.pub"
  nullable    = false

  validation {
    condition     = trimspace(var.bastion_ssh_public_key_file) != ""
    error_message = "bastion_ssh_public_key_file must not be empty."
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

variable "enable_benchmark_e6_flex" {
  description = "Whether to create a dedicated AMD E6 Flex benchmark node pool."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_benchmark_e5_flex" {
  description = "Whether to create a dedicated AMD E5 Flex benchmark node pool."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_benchmark_e6_acceleron" {
  description = "Whether to create a dedicated AMD E6 Acceleron benchmark node pool."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_benchmark_intel_optimized3" {
  description = "Whether to create a dedicated Intel Optimized3 Flex benchmark node pool."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_benchmark_intel_acceleron" {
  description = "Whether to create a dedicated Intel Acceleron benchmark node pool."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_benchmark_a4_acceleron" {
  description = "Whether to create a dedicated Ampere A4 Acceleron benchmark node pool."
  type        = bool
  default     = false
  nullable    = false
}

variable "benchmark_amd64_node_image_id" {
  description = "Optional OKE-compatible amd64 worker image OCID for selected AMD and Intel benchmark pools. Leave empty to reuse node_image_id when the primary worker architecture is amd64."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.benchmark_amd64_node_image_id == null || trimspace(var.benchmark_amd64_node_image_id) == "" || startswith(var.benchmark_amd64_node_image_id, "ocid1.image.")
    error_message = "benchmark_amd64_node_image_id must be an OCI image OCID when set."
  }
}

variable "benchmark_arm64_node_image_id" {
  description = "Optional OKE-compatible arm64 worker image OCID for the selected Ampere A4 benchmark pool. Leave empty to reuse node_image_id when the primary worker architecture is arm64."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.benchmark_arm64_node_image_id == null || trimspace(var.benchmark_arm64_node_image_id) == "" || startswith(var.benchmark_arm64_node_image_id, "ocid1.image.")
    error_message = "benchmark_arm64_node_image_id must be an OCI image OCID when set."
  }
}

variable "benchmark_pool_ocpus" {
  description = "OCPUs per dedicated benchmark node. The same value is applied to every selected Flex profile so the comparison is controlled."
  type        = number
  default     = 4
  nullable    = false

  validation {
    condition     = var.benchmark_pool_ocpus > 0
    error_message = "benchmark_pool_ocpus must be greater than zero."
  }
}

variable "benchmark_pool_memory_gbs" {
  description = "Memory in GB per dedicated benchmark node. The same value is applied to every selected Flex profile so the comparison is controlled."
  type        = number
  default     = 32
  nullable    = false

  validation {
    condition     = var.benchmark_pool_memory_gbs > 0
    error_message = "benchmark_pool_memory_gbs must be greater than zero."
  }
}

variable "benchmark_pool_initial_size" {
  description = "Number of nodes initially created in each selected dedicated benchmark pool. Use at least two for the default host-spread benchmark."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.benchmark_pool_initial_size >= 0 && floor(var.benchmark_pool_initial_size) == var.benchmark_pool_initial_size
    error_message = "benchmark_pool_initial_size must be a whole number of zero or greater."
  }
}

variable "benchmark_pool_min_size" {
  description = "Minimum node count for each selected benchmark pool when the optional Cluster Autoscaler is enabled. Use at least two for the default host-spread benchmark."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.benchmark_pool_min_size >= 0 && floor(var.benchmark_pool_min_size) == var.benchmark_pool_min_size
    error_message = "benchmark_pool_min_size must be a whole number of zero or greater."
  }
}

variable "benchmark_pool_max_size" {
  description = "Maximum node count for each selected benchmark pool when the optional Cluster Autoscaler is enabled."
  type        = number
  default     = 4
  nullable    = false

  validation {
    condition     = var.benchmark_pool_max_size >= 1 && floor(var.benchmark_pool_max_size) == var.benchmark_pool_max_size
    error_message = "benchmark_pool_max_size must be a whole number of at least one."
  }
}

variable "benchmark_pool_max_pods_per_node" {
  description = "Maximum VCN-native Pods per node in each selected benchmark pool. Validate it against the selected shape's VNIC capacity."
  type        = number
  default     = 31
  nullable    = false

  validation {
    condition     = var.benchmark_pool_max_pods_per_node >= 1 && floor(var.benchmark_pool_max_pods_per_node) == var.benchmark_pool_max_pods_per_node
    error_message = "benchmark_pool_max_pods_per_node must be a whole number of at least one."
  }
}

variable "benchmark_node_pools_json" {
  description = "Advanced Terraform-only JSON object for custom benchmark shapes not offered by the guided profile controls. Each property name is a profile ID and each value supplies node_shape, node_image_id, architecture, initial_size, min_size, max_size, and, for Flex shapes, ocpus and memory_in_gbs."
  type        = string
  default     = "{}"
  nullable    = false

  validation {
    condition = can({
      for profile_id, profile in jsondecode(var.benchmark_node_pools_json) : profile_id => [
        profile.node_shape,
        profile.node_image_id,
        profile.architecture,
        profile.initial_size,
        profile.min_size,
        profile.max_size,
      ]
    })
    error_message = "benchmark_node_pools_json must be a JSON object whose profiles define node_shape, node_image_id, architecture, initial_size, min_size, and max_size."
  }
}

variable "enable_benchmark_cluster_autoscaler" {
  description = "Whether Terraform installs the OKE Cluster Autoscaler add-on to enforce the minimum and maximum node counts of selected dedicated benchmark pools."
  type        = bool
  default     = false
  nullable    = false
}

variable "create_benchmark_cluster_autoscaler_workload_identity_policy" {
  description = "Whether Terraform creates the condition-scoped workload identity policy that lets the OKE Cluster Autoscaler add-on resize the selected benchmark node pools and their underlying compute and network resources."
  type        = bool
  default     = true
  nullable    = false
}

variable "benchmark_cluster_autoscaler_remove_resources_on_destroy" {
  description = "Whether Terraform asks OKE to remove Cluster Autoscaler Kubernetes resources when this stack removes the add-on."
  type        = bool
  default     = true
  nullable    = false
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

variable "operator_kubernetes_access_mode" {
  description = "How the private operator is authorized to use the Kubernetes API. iam_admin grants cluster administration scoped to this cluster; namespace_rbac uses a generated namespace-scoped Kubernetes RoleBinding. FSS result delivery requires iam_admin because it creates a static cluster-scoped PersistentVolume."
  type        = string
  default     = "iam_admin"
  nullable    = false

  validation {
    condition     = contains(["iam_admin", "namespace_rbac"], trimspace(var.operator_kubernetes_access_mode))
    error_message = "operator_kubernetes_access_mode must be iam_admin or namespace_rbac."
  }
}

variable "operator_bootstrap_generation" {
  description = "Increment this whole number to intentionally replace the private operator VM after changing the runtime bundle or benchmark-profile configuration."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.operator_bootstrap_generation >= 1 && floor(var.operator_bootstrap_generation) == var.operator_bootstrap_generation
    error_message = "operator_bootstrap_generation must be a positive whole number."
  }
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

variable "result_delivery_mode" {
  description = "Where simulation workers publish immutable partial results. object_storage uses OKE Workload Identity and Object Storage; fss uses a private OCI File Storage share mounted through the FSS CSI driver."
  type        = string
  default     = "fss"
  nullable    = false

  validation {
    condition     = contains(["object_storage", "fss"], trimspace(var.result_delivery_mode))
    error_message = "result_delivery_mode must be object_storage or fss."
  }
}

variable "fss_export_path" {
  description = "NFS export path for FSS result delivery. Used only when result_delivery_mode is fss."
  type        = string
  default     = "/monte-carlo-results"
  nullable    = false

  validation {
    condition     = can(regex("^/[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$", var.fss_export_path))
    error_message = "fss_export_path must be an absolute NFS export path using letters, numbers, dots, underscores, and hyphens."
  }
}

variable "fss_operator_mount_path" {
  description = "Private path on the operator VM where the FSS results export is mounted. Used only when result_delivery_mode is fss."
  type        = string
  default     = "/mnt/mcqs-results"
  nullable    = false

  validation {
    condition     = can(regex("^/[A-Za-z0-9][A-Za-z0-9._/-]*$", var.fss_operator_mount_path)) && !endswith(var.fss_operator_mount_path, "/")
    error_message = "fss_operator_mount_path must be an absolute path without a trailing slash."
  }
}

variable "fss_persistent_volume_capacity" {
  description = "Kubernetes capacity value required by the static FSS PersistentVolume. OCI File Storage is elastic and does not enforce this value."
  type        = string
  default     = "50Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[1-9][0-9]*(Mi|Gi|Ti)$", var.fss_persistent_volume_capacity))
    error_message = "fss_persistent_volume_capacity must use an integer Kubernetes binary unit, for example 50Gi."
  }
}

variable "create_workload_object_storage_policy" {
  description = "Whether Terraform creates the condition-scoped OKE Workload Identity policy that lets the configured Kubernetes ServiceAccount create result objects below the configured Object Storage prefix. It is used only when result_delivery_mode is object_storage."
  type        = bool
  default     = true
  nullable    = false
}

variable "create_operator_dynamic_group" {
  description = "Whether Terraform creates the dynamic group that identifies the private operator instance principal."
  type        = bool
  default     = true
  nullable    = false
}

variable "operator_dynamic_group_ocid" {
  description = "OCID of an existing dynamic group to use when Terraform does not create the operator dynamic group."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.operator_dynamic_group_ocid == null || startswith(var.operator_dynamic_group_ocid, "ocid1.dynamicgroup.")
    error_message = "operator_dynamic_group_ocid must be an OCI dynamic group OCID (ocid1.dynamicgroup...) when set."
  }
}

variable "create_operator_cluster_access_policy" {
  description = "Whether Terraform creates the policy that lets the private operator obtain and use the kubeconfig for this OKE cluster."
  type        = bool
  default     = true
  nullable    = false
}

variable "create_operator_bootstrap_bundle_read_policy" {
  description = "Whether Terraform creates the policy that lets the private operator download its private bootstrap bundle from Object Storage."
  type        = bool
  default     = true
  nullable    = false
}

variable "create_operator_results_read_policy" {
  description = "Whether Terraform creates the policy that lets the private operator read simulation results from Object Storage. It is used only when result_delivery_mode is object_storage."
  type        = bool
  default     = true
  nullable    = false
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
