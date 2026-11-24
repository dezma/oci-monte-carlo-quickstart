# Copy values into terraform/terraform.tfvars after setting tenancy, compartment, region, and bastion_client_cidr.
# Verify VM.Standard.E5.Flex is available in the selected Availability Domain first.
node_shape            = "VM.Standard.E5.Flex"
node_shape_ocpus      = 4
node_shape_memory_gbs = 32
node_pool_size        = 2
max_pods_per_node     = 31
node_architecture     = "amd64"

# Submit with: ./operator/run-example.sh --parallelism 4 --architecture amd64
