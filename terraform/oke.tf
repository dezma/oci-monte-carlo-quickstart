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
    nsg_ids = [oci_core_network_security_group.oke_internal.id]

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
