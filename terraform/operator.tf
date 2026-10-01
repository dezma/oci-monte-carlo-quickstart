data "oci_core_images" "operator" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = local.operator_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "state"
    values = ["AVAILABLE"]
  }
}

locals {
  operator_image_id = coalesce(var.operator_image_id, try(data.oci_core_images.operator.images[0].id, null))
}

resource "terraform_data" "operator_image" {
  input = local.operator_image_id

  lifecycle {
    precondition {
      condition     = local.operator_image_id != null
      error_message = "No Oracle Linux 8 platform image was found. Set operator_image_id to an approved compatible image OCID."
    }
  }
}

resource "oci_bastion_bastion" "operator" {
  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_ocid
  target_subnet_id             = oci_core_subnet.bastion.id
  name                         = "${var.name_prefix}-operator-bastion"
  client_cidr_block_allow_list = [var.bastion_client_cidr]
  max_session_ttl_in_seconds   = 3600
  freeform_tags                = local.tags
}

resource "oci_core_instance" "operator" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.name_prefix}-operator"
  shape               = local.operator_shape
  freeform_tags       = local.tags

  shape_config {
    ocpus         = var.operator_shape_ocpus
    memory_in_gbs = var.operator_shape_memory_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.operator.id
    assign_public_ip = false
    display_name     = "${var.name_prefix}-operator-vnic"
    nsg_ids          = [oci_core_network_security_group.operator.id]
  }

  source_details {
    source_type             = "image"
    source_id               = local.operator_image_id
    boot_volume_size_in_gbs = var.operator_boot_volume_gbs
  }

  agent_config {
    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    user_data = base64encode(templatefile("${path.module}/operator/cloud-init.sh.tftpl", {
      bucket_name           = oci_objectstorage_bucket.results.name
      namespace             = data.oci_objectstorage_namespace.this.namespace
      bundle_name           = local.operator_bundle_name
      bundle_sha256         = local.operator_bundle_sha256
      cluster_id            = oci_containerengine_cluster.this.id
      region                = var.region
      kubectl_version       = local.operator_kubectl_version
      helm_version          = var.operator_helm_version
      node_architecture     = local.node_architecture
      image_repository      = local.container_repository_url
      object_storage_prefix = var.object_storage_prefix
      service_account_name  = var.service_account_name
      kubernetes_namespace  = var.kubernetes_namespace
    }))
  }

  depends_on = [
    terraform_data.operator_image,
    oci_objectstorage_object.operator_bundle,
  ]
}
