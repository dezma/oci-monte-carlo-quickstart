data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

# Preserve the initial operator and FSS placement when a later update moves
# only worker pools to a different Availability Domain for Compute capacity.
# Explicit placement inputs always take precedence and remain intentional
# relocation controls.
resource "terraform_data" "placement_defaults" {
  input = {
    operator_availability_domain = coalesce(var.operator_availability_domain, local.availability_domain)
    fss_availability_domain      = coalesce(var.fss_availability_domain, local.availability_domain)
  }

  lifecycle {
    ignore_changes = [input]
  }
}

locals {
  # The optional placement controls let a new deployment pin the Bastion-
  # reached operator and FSS independently. When omitted, the stack retains
  # their first placement even if worker pools later move for capacity.
  availability_domain          = coalesce(var.availability_domain, data.oci_identity_availability_domains.this.availability_domains[0].name)
  operator_availability_domain = coalesce(var.operator_availability_domain, try(terraform_data.placement_defaults.output.operator_availability_domain, null), local.availability_domain)
  fss_availability_domain      = coalesce(var.fss_availability_domain, try(terraform_data.placement_defaults.output.fss_availability_domain, null), local.availability_domain)
  kubernetes_version  = trimspace(var.kubernetes_version)
  node_architecture   = trimspace(var.node_architecture)
  result_delivery_mode = trimspace(var.result_delivery_mode)
  object_storage_result_delivery = local.result_delivery_mode == "object_storage"
  fss_enabled                    = local.result_delivery_mode == "fss"
  fss_mount_target_ip            = coalesce(var.fss_mount_target_ip, cidrhost(var.fss_subnet_cidr, 10))
  # Bind every FSS filesystem generation to distinct Kubernetes PV/PVC names.
  # A PersistentVolume source is immutable, so a deliberate filesystem or
  # mount-target replacement must receive a fresh binding instead of trying to
  # repoint an existing volume.
  fss_binding_suffix                = local.fss_enabled ? substr(sha1(oci_file_storage_file_system.results[0].id), 0, 10) : ""
  fss_persistent_volume_name        = local.fss_enabled ? "${local.resource_prefix}-mcqs-results-${local.fss_binding_suffix}" : ""
  fss_persistent_volume_claim_name  = local.fss_enabled ? "monte-carlo-results-${local.fss_binding_suffix}" : "monte-carlo-results"
  operator_shape      = coalesce(var.operator_shape, local.node_architecture == "arm64" ? "VM.Standard.A4.Flex" : "VM.Standard.E5.Flex")
  operator_kubernetes_access_mode = trimspace(var.operator_kubernetes_access_mode)
  operator_cluster_verb           = local.operator_kubernetes_access_mode == "iam_admin" ? "manage" : "use"
  operator_dynamic_group_name     = "${local.resource_prefix}-mcqs-operator"
  operator_dynamic_group_ocid     = var.create_operator_dynamic_group ? try(oci_identity_dynamic_group.operator[0].id, null) : var.operator_dynamic_group_ocid
  operator_identity_is_referenced = var.create_operator_cluster_access_policy || var.create_operator_bootstrap_bundle_read_policy || (local.object_storage_result_delivery && var.create_operator_results_read_policy) || local.operator_kubernetes_access_mode == "namespace_rbac"
  resource_prefix     = substr(replace(var.name_prefix, "-", ""), 0, 12)
  bucket_name         = coalesce(var.object_storage_bucket_name, "${local.resource_prefix}-monte-carlo-results")
  ocir_region_key = lower(one([
    for subscription in data.oci_identity_region_subscriptions.this.region_subscriptions : subscription.region_key
    if subscription.region_name == var.region
  ]))
  ocir_registry            = coalesce(var.ocir_registry, "${local.ocir_region_key}.ocir.io")
  container_repository_url = "${local.ocir_registry}/${oci_artifacts_container_repository.monte_carlo.namespace}/${oci_artifacts_container_repository.monte_carlo.display_name}"
  fss_volume_handle       = local.fss_enabled ? "${oci_file_storage_file_system.results[0].id}:${local.fss_mount_target_ip}:${var.fss_export_path}" : ""
  operator_bundle_path     = "${path.module}/operator/payload/monte-carlo-quickstart.tar.gz"
  operator_bundle_sha256   = filesha256(local.operator_bundle_path)
  operator_bundle_name     = "bootstrap/monte-carlo-quickstart-${substr(local.operator_bundle_sha256, 0, 16)}.tar.gz"
  operator_kubectl_version = startswith(local.kubernetes_version, "v") ? local.kubernetes_version : "v${local.kubernetes_version}"
  cluster_private_endpoint_parts = regex("^(.+):([0-9]+)$", oci_containerengine_cluster.this.endpoints[0].private_endpoint)
  cluster_private_api_ip         = local.cluster_private_endpoint_parts[0]
  cluster_private_api_port       = tonumber(local.cluster_private_endpoint_parts[1])
  benchmark_amd64_image_id = coalesce(
    var.benchmark_amd64_node_image_id,
    local.node_architecture == "amd64" ? var.node_image_id : null,
    "",
  )
  benchmark_arm64_image_id = coalesce(
    var.benchmark_arm64_node_image_id,
    local.node_architecture == "arm64" ? var.node_image_id : null,
    "",
  )
  benchmark_preset_node_pools = merge(
    var.enable_benchmark_e5_flex ? {
      "e5-flex" = {
        profile_id        = "e5-flex"
        node_shape        = "VM.Standard.E5.Flex"
        node_image_id     = local.benchmark_amd64_image_id
        architecture      = "amd64"
        initial_size      = var.benchmark_pool_initial_size
        min_size          = var.benchmark_pool_min_size
        max_size          = var.benchmark_pool_max_size
        max_pods_per_node = var.benchmark_pool_max_pods_per_node
        ocpus             = var.benchmark_pool_ocpus
        memory_in_gbs     = var.benchmark_pool_memory_gbs
        is_flex_shape     = true
      }
    } : {},
    var.enable_benchmark_e6_flex ? {
      "e6-flex" = {
        profile_id        = "e6-flex"
        node_shape        = "VM.Standard.E6.Flex"
        node_image_id     = local.benchmark_amd64_image_id
        architecture      = "amd64"
        initial_size      = var.benchmark_pool_initial_size
        min_size          = var.benchmark_pool_min_size
        max_size          = var.benchmark_pool_max_size
        max_pods_per_node = var.benchmark_pool_max_pods_per_node
        ocpus             = var.benchmark_pool_ocpus
        memory_in_gbs     = var.benchmark_pool_memory_gbs
        is_flex_shape     = true
      }
    } : {},
    var.enable_benchmark_e6_acceleron ? {
      "e6-acceleron" = {
        profile_id        = "e6-acceleron"
        node_shape        = "VM.Standard.E6.Ax.Flex"
        node_image_id     = local.benchmark_amd64_image_id
        architecture      = "amd64"
        initial_size      = var.benchmark_pool_initial_size
        min_size          = var.benchmark_pool_min_size
        max_size          = var.benchmark_pool_max_size
        max_pods_per_node = var.benchmark_pool_max_pods_per_node
        ocpus             = var.benchmark_pool_ocpus
        memory_in_gbs     = var.benchmark_pool_memory_gbs
        is_flex_shape     = true
      }
    } : {},
    var.enable_benchmark_intel_optimized3 ? {
      "intel-optimized3" = {
        profile_id        = "intel-optimized3"
        node_shape        = "VM.Optimized3.Flex"
        node_image_id     = local.benchmark_amd64_image_id
        architecture      = "amd64"
        initial_size      = var.benchmark_pool_initial_size
        min_size          = var.benchmark_pool_min_size
        max_size          = var.benchmark_pool_max_size
        max_pods_per_node = var.benchmark_pool_max_pods_per_node
        ocpus             = var.benchmark_pool_ocpus
        memory_in_gbs     = var.benchmark_pool_memory_gbs
        is_flex_shape     = true
      }
    } : {},
    var.enable_benchmark_intel_acceleron ? {
      "intel-acceleron" = {
        profile_id        = "intel-acceleron"
        node_shape        = "VM.Standard4.Ax.Flex"
        node_image_id     = local.benchmark_amd64_image_id
        architecture      = "amd64"
        initial_size      = var.benchmark_pool_initial_size
        min_size          = var.benchmark_pool_min_size
        max_size          = var.benchmark_pool_max_size
        max_pods_per_node = var.benchmark_pool_max_pods_per_node
        ocpus             = var.benchmark_pool_ocpus
        memory_in_gbs     = var.benchmark_pool_memory_gbs
        is_flex_shape     = true
      }
    } : {},
    var.enable_benchmark_a4_acceleron ? {
      "a4-acceleron" = {
        profile_id        = "a4-acceleron"
        node_shape        = "VM.Standard.A4.Ax.Flex"
        node_image_id     = local.benchmark_arm64_image_id
        architecture      = "arm64"
        initial_size      = var.benchmark_pool_initial_size
        min_size          = var.benchmark_pool_min_size
        max_size          = var.benchmark_pool_max_size
        max_pods_per_node = var.benchmark_pool_max_pods_per_node
        ocpus             = var.benchmark_pool_ocpus
        memory_in_gbs     = var.benchmark_pool_memory_gbs
        is_flex_shape     = true
      }
    } : {},
  )
  benchmark_advanced_node_pools_input = coalesce(try(jsondecode(var.benchmark_node_pools_json), null), {})
  benchmark_advanced_node_pools = try({
    for profile_id, profile in local.benchmark_advanced_node_pools_input : tostring(profile_id) => {
      profile_id        = tostring(profile_id)
      node_shape        = try(trimspace(tostring(profile.node_shape)), "")
      node_image_id     = try(trimspace(tostring(profile.node_image_id)), "")
      architecture      = try(trimspace(tostring(profile.architecture)), "")
      initial_size      = try(tonumber(profile.initial_size), 0)
      min_size          = try(tonumber(profile.min_size), 0)
      max_size          = try(tonumber(profile.max_size), 0)
      max_pods_per_node = try(tonumber(profile.max_pods_per_node), var.max_pods_per_node)
      ocpus             = try(tonumber(profile.ocpus), null)
      memory_in_gbs     = try(tonumber(profile.memory_in_gbs), null)
      is_flex_shape     = can(regex("Flex$", try(tostring(profile.node_shape), "")))
    }
  }, {})
  benchmark_node_pools = merge(local.benchmark_preset_node_pools, local.benchmark_advanced_node_pools)
  benchmark_profiles = local.benchmark_node_pools
  benchmark_profile_label_key = "benchmark.oracle.com/profile"
  benchmark_profile_taint_key = "benchmark.oracle.com/profile"
  benchmark_profile_taint_effect = "NoSchedule"
  benchmark_cluster_autoscaler_enabled = var.enable_benchmark_cluster_autoscaler && length(local.benchmark_node_pools) > 0
  benchmark_node_pool_profiles_json = jsonencode({
    for profile_id, profile in local.benchmark_profiles : profile_id => {
      architecture = profile.architecture
      initial_size = profile.initial_size
      min_size     = profile.min_size
      max_size     = profile.max_size
      node_shape   = profile.node_shape
      selector     = {
        key   = local.benchmark_profile_label_key
        value = profile_id
      }
      taint = {
        key    = local.benchmark_profile_taint_key
        value  = profile_id
        effect = local.benchmark_profile_taint_effect
      }
    }
  })
  tags = merge(
    {
      Project     = "oci-monte-carlo-quickstart"
      ManagedBy   = "terraform"
      Environment = "quickstart"
    },
    var.freeform_tags,
  )
}
