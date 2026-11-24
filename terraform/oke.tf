resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = local.kubernetes_version
  name               = "${var.name_prefix}-oke"
  type               = "ENHANCED_CLUSTER"
  vcn_id             = oci_core_vcn.this.id
  freeform_tags      = local.tags

  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  endpoint_config {
    is_public_ip_enabled = false
    subnet_id            = oci_core_subnet.api.id
    nsg_ids = [
      oci_core_network_security_group.oke_internal.id,
      oci_core_network_security_group.api_operator.id,
    ]
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.service_lb.id]

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }
}

locals {
  is_flex_shape = can(regex("Flex$", var.node_shape))
}

resource "terraform_data" "benchmark_node_pool_validation" {
  for_each = local.benchmark_node_pools

  input = each.value

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", each.key)) && length(each.key) <= 63
      error_message = "Each benchmark-node-pool profile ID must be a Kubernetes label value of 63 lowercase letters, digits, and hyphens or fewer."
    }

    precondition {
      condition     = each.value.node_shape != "" && each.value.node_image_id != "" && startswith(each.value.node_image_id, "ocid1.image.")
      error_message = "Each benchmark node pool requires node_shape and a compatible node_image_id OCI image OCID."
    }

    precondition {
      condition     = contains(["amd64", "arm64"], each.value.architecture)
      error_message = "Each benchmark node pool architecture must be amd64 or arm64."
    }

    precondition {
      condition     = each.value.min_size >= 0 && each.value.initial_size >= each.value.min_size && each.value.initial_size <= each.value.max_size && each.value.max_size >= 1
      error_message = "Each benchmark node pool must use 0 <= min_size <= initial_size <= max_size, with max_size at least 1."
    }

    precondition {
      condition     = each.value.max_pods_per_node >= 1
      error_message = "Each benchmark node pool max_pods_per_node must be at least 1."
    }

    precondition {
      condition     = !each.value.is_flex_shape || (try(each.value.ocpus > 0, false) && try(each.value.memory_in_gbs > 0, false))
      error_message = "Each flexible benchmark node shape requires positive ocpus and memory_in_gbs values."
    }

    precondition {
      condition     = each.value.is_flex_shape || (each.value.ocpus == null && each.value.memory_in_gbs == null)
      error_message = "Fixed-shape benchmark node pools must omit ocpus and memory_in_gbs."
    }
  }
}

resource "terraform_data" "benchmark_cluster_autoscaler_validation" {
  input = {
    enabled        = var.enable_benchmark_cluster_autoscaler
    selected_pools = length(local.benchmark_node_pools)
  }

  lifecycle {
    precondition {
      condition     = !var.enable_benchmark_cluster_autoscaler || length(local.benchmark_node_pools) > 0
      error_message = "Enable benchmark-pool autoscaling only after selecting at least one guided benchmark profile or defining an advanced custom profile."
    }

    precondition {
      condition     = !(var.enable_benchmark_e5_flex || var.enable_benchmark_e6_flex || var.enable_benchmark_e6_acceleron || var.enable_benchmark_intel_optimized3 || var.enable_benchmark_intel_acceleron) || local.benchmark_amd64_image_id != ""
      error_message = "Select an amd64 OKE worker image for the AMD or Intel benchmark profiles, or use an amd64 primary worker image that Terraform can reuse."
    }

    precondition {
      condition     = !var.enable_benchmark_a4_acceleron || local.benchmark_arm64_image_id != ""
      error_message = "Select an arm64 OKE worker image for the Ampere A4 benchmark profile, or use an arm64 primary worker image that Terraform can reuse."
    }

    precondition {
      condition     = var.benchmark_pool_min_size <= var.benchmark_pool_initial_size && var.benchmark_pool_initial_size <= var.benchmark_pool_max_size
      error_message = "For guided benchmark profiles, use benchmark_pool_min_size <= benchmark_pool_initial_size <= benchmark_pool_max_size."
    }

    precondition {
      condition     = length(setintersection(toset(keys(local.benchmark_preset_node_pools)), toset(keys(local.benchmark_advanced_node_pools)))) == 0
      error_message = "Do not define the same profile through both the guided selection controls and benchmark_node_pools_json."
    }
  }
}

resource "oci_containerengine_node_pool" "workers" {
  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = local.kubernetes_version
  name               = "${var.name_prefix}-workers"
  node_shape         = var.node_shape
  freeform_tags      = local.tags

  initial_node_labels {
    key   = "workload.oracle.com/monte-carlo"
    value = "true"
  }

  node_config_details {
    size    = var.node_pool_size
    nsg_ids = concat(
      [oci_core_network_security_group.oke_internal.id],
      local.fss_enabled ? [oci_core_network_security_group.fss_worker_client[0].id] : [],
    )

    placement_configs {
      availability_domain = local.availability_domain
      subnet_id           = oci_core_subnet.worker.id
    }

    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = var.max_pods_per_node
      pod_nsg_ids       = [oci_core_network_security_group.oke_internal.id]
      pod_subnet_ids    = [oci_core_subnet.pod.id]
    }
  }

  dynamic "node_shape_config" {
    for_each = local.is_flex_shape ? [1] : []
    content {
      ocpus         = var.node_shape_ocpus
      memory_in_gbs = var.node_shape_memory_gbs
    }
  }

  node_source_details {
    image_id    = var.node_image_id
    source_type = "IMAGE"
  }

  node_pool_cycling_details {
    is_node_cycling_enabled = true
    maximum_surge           = "1"
    maximum_unavailable     = "0"
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

# The main worker pool intentionally remains outside the Cluster Autoscaler.
# It keeps essential OKE add-ons schedulable while dedicated benchmark pools
# scale independently between their declared minimum and maximum sizes.
resource "oci_containerengine_node_pool" "benchmark" {
  for_each = local.benchmark_node_pools

  cluster_id         = oci_containerengine_cluster.this.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = local.kubernetes_version
  name               = "${var.name_prefix}-benchmark-${each.key}"
  node_shape         = each.value.node_shape
  freeform_tags = merge(local.tags, {
    "mcqs-benchmark-profile" = each.key
  })

  initial_node_labels {
    key   = local.benchmark_profile_label_key
    value = each.key
  }

  initial_node_labels {
    key   = "workload.oracle.com/monte-carlo"
    value = "true"
  }

  node_config_details {
    size = each.value.initial_size
    nsg_ids = concat(
      [oci_core_network_security_group.oke_internal.id],
      local.fss_enabled ? [oci_core_network_security_group.fss_worker_client[0].id] : [],
    )

    placement_configs {
      availability_domain = local.availability_domain
      subnet_id           = oci_core_subnet.worker.id
    }

    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = each.value.max_pods_per_node
      pod_nsg_ids       = [oci_core_network_security_group.oke_internal.id]
      pod_subnet_ids    = [oci_core_subnet.pod.id]
    }
  }

  dynamic "node_shape_config" {
    for_each = each.value.is_flex_shape ? [each.value] : []
    content {
      ocpus         = node_shape_config.value.ocpus
      memory_in_gbs = node_shape_config.value.memory_in_gbs
    }
  }

  node_source_details {
    image_id    = each.value.node_image_id
    source_type = "IMAGE"
  }

  node_pool_cycling_details {
    is_node_cycling_enabled = true
    maximum_surge           = "1"
    maximum_unavailable     = "0"
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  # Cluster Autoscaler changes this value at runtime. Keeping it out of
  # Terraform drift reconciliation prevents a later plan from undoing a
  # valid scale-out or scale-in on a dedicated benchmark pool.
  lifecycle {
    ignore_changes = [node_config_details[0].size]
  }

  depends_on = [terraform_data.benchmark_node_pool_validation]
}

resource "oci_containerengine_addon" "benchmark_cluster_autoscaler" {
  count = local.benchmark_cluster_autoscaler_enabled ? 1 : 0

  addon_name                         = "ClusterAutoscaler"
  cluster_id                         = oci_containerengine_cluster.this.id
  remove_addon_resources_on_delete   = var.benchmark_cluster_autoscaler_remove_resources_on_destroy
  override_existing                  = false

  configurations {
    key = "nodes"
    value = join(",", [
      for profile_id in sort(keys(local.benchmark_node_pools)) :
      "${local.benchmark_node_pools[profile_id].min_size}:${local.benchmark_node_pools[profile_id].max_size}:${oci_containerengine_node_pool.benchmark[profile_id].id}"
    ])
  }

  configurations {
    key   = "authType"
    value = "workload"
  }

  depends_on = [
    terraform_data.benchmark_cluster_autoscaler_validation,
    oci_containerengine_node_pool.benchmark,
    oci_identity_policy.benchmark_cluster_autoscaler_workload_identity,
  ]
}
