# Optional shared result filesystem. The static Kubernetes PV created by the
# baseline chart points at this file system; individual simulation releases
# only mount its namespace-scoped claim.

resource "terraform_data" "fss_result_delivery" {
  input = {
    enabled                = local.fss_enabled
    kubernetes_access_mode = local.operator_kubernetes_access_mode
  }

  lifecycle {
    # A static PV is cluster-scoped. The namespace_rbac mode deliberately does
    # not grant the private operator cluster-wide PV permissions, so select the
    # cluster-scoped iam_admin access mode for this automated FSS path.
    precondition {
      condition     = !local.fss_enabled || local.operator_kubernetes_access_mode == "iam_admin"
      error_message = "result_delivery_mode = fss requires operator_kubernetes_access_mode = iam_admin because the baseline creates a cluster-scoped static FSS PersistentVolume."
    }
  }
}

resource "oci_core_network_security_group" "fss_mount_target" {
  count          = local.fss_enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-fss-mount-target"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group" "fss_worker_client" {
  count          = local.fss_enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-fss-worker-client"
  freeform_tags  = local.tags
}

locals {
  fss_tcp_ports = toset([111, 2048, 2049, 2050])
  fss_udp_ports = toset([111, 2048])

  # Terraform can iterate only strings in a set, or keys in a map. Keep the
  # port number as the map value so the NSG rule still receives a number.
  fss_tcp_egress_rules = local.fss_enabled ? {
    for port in local.fss_tcp_ports : tostring(port) => port
  } : {}
  fss_udp_egress_rules = local.fss_enabled ? {
    for port in local.fss_udp_ports : tostring(port) => port
  } : {}

  fss_clients = local.fss_enabled ? {
    worker   = oci_core_network_security_group.fss_worker_client[0].id
    operator = oci_core_network_security_group.operator.id
  } : {}
  fss_client_tcp_rules = local.fss_enabled ? {
    for pair in setproduct(keys(local.fss_clients), local.fss_tcp_ports) : "${pair[0]}-${pair[1]}" => {
      client = pair[0]
      port   = pair[1]
    }
  } : {}
  fss_client_udp_rules = local.fss_enabled ? {
    for pair in setproduct(keys(local.fss_clients), local.fss_udp_ports) : "${pair[0]}-${pair[1]}" => {
      client = pair[0]
      port   = pair[1]
    }
  } : {}
}

# OCI File Storage requires ONC RPC, NFS, mount, and lock-manager traffic. The
# FSS NSG admits it only from the worker-client NSG and the private operator.
resource "oci_core_network_security_group_security_rule" "fss_mount_target_ingress_tcp" {
  for_each                  = local.fss_client_tcp_rules
  network_security_group_id = oci_core_network_security_group.fss_mount_target[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.fss_clients[each.value.client]
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "OCI File Storage TCP port ${each.value.port} from the ${each.value.client} client group."

  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "fss_mount_target_ingress_udp" {
  for_each                  = local.fss_client_udp_rules
  network_security_group_id = oci_core_network_security_group.fss_mount_target[0].id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = local.fss_clients[each.value.client]
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "OCI File Storage UDP port ${each.value.port} from the ${each.value.client} client group."

  udp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

# Explicit egress allows this design to keep working if the VCN's broad
# private-baseline egress rule is later tightened by the platform team.
resource "oci_core_network_security_group_security_rule" "fss_worker_egress_tcp" {
  for_each                  = local.fss_tcp_egress_rules
  network_security_group_id = oci_core_network_security_group.fss_worker_client[0].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.fss_mount_target[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "OCI File Storage TCP port ${each.value} from worker nodes."

  tcp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

resource "oci_core_network_security_group_security_rule" "fss_worker_egress_udp" {
  for_each                  = local.fss_udp_egress_rules
  network_security_group_id = oci_core_network_security_group.fss_worker_client[0].id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = oci_core_network_security_group.fss_mount_target[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "OCI File Storage UDP port ${each.value} from worker nodes."

  udp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

resource "oci_core_network_security_group_security_rule" "fss_operator_egress_tcp" {
  for_each                  = local.fss_tcp_egress_rules
  network_security_group_id = oci_core_network_security_group.operator.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.fss_mount_target[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "OCI File Storage TCP port ${each.value} from the private operator."

  tcp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

resource "oci_core_network_security_group_security_rule" "fss_operator_egress_udp" {
  for_each                  = local.fss_udp_egress_rules
  network_security_group_id = oci_core_network_security_group.operator.id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = oci_core_network_security_group.fss_mount_target[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "OCI File Storage UDP port ${each.value} from the private operator."

  udp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

resource "oci_file_storage_file_system" "results" {
  count               = local.fss_enabled ? 1 : 0
  availability_domain = local.fss_availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.name_prefix}-monte-carlo-results"
  freeform_tags       = local.tags

  depends_on = [terraform_data.fss_result_delivery]
}

resource "oci_file_storage_mount_target" "results" {
  count               = local.fss_enabled ? 1 : 0
  availability_domain = local.fss_availability_domain
  compartment_id      = var.compartment_ocid
  subnet_id           = oci_core_subnet.fss[0].id
  display_name        = "${var.name_prefix}-monte-carlo-results"
  ip_address          = local.fss_mount_target_ip
  nsg_ids             = [oci_core_network_security_group.fss_mount_target[0].id]
  freeform_tags       = local.tags
}

# The operator is allowed to initialize and aggregate the shared tree. Worker
# nodes are all-squashed to the non-root UID/GID used by the simulator image.
# The two source CIDRs do not overlap, so each client matches exactly one rule.
resource "oci_file_storage_export" "results" {
  count          = local.fss_enabled ? 1 : 0
  export_set_id  = oci_file_storage_mount_target.results[0].export_set_id
  file_system_id = oci_file_storage_file_system.results[0].id
  path           = var.fss_export_path

  export_options {
    source                         = oci_core_subnet.operator.cidr_block
    access                         = "READ_WRITE"
    identity_squash                = "NONE"
    require_privileged_source_port = true
    allowed_auth                  = ["SYS"]
  }

  export_options {
    source                         = oci_core_subnet.worker.cidr_block
    access                         = "READ_WRITE"
    identity_squash                = "ALL"
    anonymous_uid                  = 10001
    anonymous_gid                  = 10001
    require_privileged_source_port = true
    allowed_auth                   = ["SYS"]
  }
}
