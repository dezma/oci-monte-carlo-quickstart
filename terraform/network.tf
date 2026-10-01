data "oci_core_services" "oracle_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = "mcqs"
  freeform_tags  = local.tags
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nat"
  freeform_tags  = local.tags
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-service-gateway"
  freeform_tags  = local.tags

  services {
    service_id = data.oci_core_services.oracle_services.services[0].id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-private-rt"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  route_rules {
    destination       = data.oci_core_services.oracle_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
}

resource "oci_core_security_list" "private_baseline" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-private-baseline-sl"
  freeform_tags  = local.tags

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "Egress is constrained by workload NetworkPolicy and NSGs."
  }
}

resource "oci_core_subnet" "api" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.api_subnet_cidr
  display_name               = "${var.name_prefix}-api-private"
  dns_label                  = "api"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private_baseline.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "operator" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.operator_subnet_cidr
  display_name               = "${var.name_prefix}-operator-private"
  dns_label                  = "operator"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private_baseline.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}

resource "oci_core_security_list" "bastion" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-bastion-sl"
  freeform_tags  = local.tags

  egress_security_rules {
    protocol         = "6"
    destination      = oci_core_subnet.operator.cidr_block
    destination_type = "CIDR_BLOCK"
    description      = "OCI Bastion managed SSH access to the private operator only."

    tcp_options {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_subnet" "bastion" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.bastion_subnet_cidr
  display_name               = "${var.name_prefix}-bastion-private"
  dns_label                  = "bastion"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.bastion.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "worker" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.worker_subnet_cidr
  display_name               = "${var.name_prefix}-worker-private"
  dns_label                  = "worker"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private_baseline.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "pod" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.pod_subnet_cidr
  display_name               = "${var.name_prefix}-pod-private"
  dns_label                  = "pod"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private_baseline.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "service_lb" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.service_lb_subnet_cidr
  display_name               = "${var.name_prefix}-service-lb-private"
  dns_label                  = "svclb"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private_baseline.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.tags
}

resource "oci_core_network_security_group" "oke_internal" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-oke-internal"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "oke_internal_ingress" {
  network_security_group_id = oci_core_network_security_group.oke_internal.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.oke_internal.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "OKE control plane, worker, and pod traffic inside the dedicated security group."
}

resource "oci_core_network_security_group_security_rule" "oke_internal_egress" {
  network_security_group_id = oci_core_network_security_group.oke_internal.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Required egress. Kubernetes NetworkPolicy further limits application pods."
}

resource "oci_core_network_security_group" "api_operator" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-api-operator"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "api_operator_ingress" {
  network_security_group_id = oci_core_network_security_group.api_operator.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_subnet.operator.cidr_block
  source_type               = "CIDR_BLOCK"
  description               = "Private operator subnet to Kubernetes API only."

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group" "operator" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-operator"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "operator_bastion_ssh_ingress" {
  network_security_group_id = oci_core_network_security_group.operator.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_subnet.bastion.cidr_block
  source_type               = "CIDR_BLOCK"
  description               = "Managed SSH sessions from the OCI Bastion private endpoint only."

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}
