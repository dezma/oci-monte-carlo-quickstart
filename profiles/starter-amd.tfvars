# Copy values into terraform/terraform.tfvars after setting tenancy, compartment, region, and bastion_client_cidr.
node_shape            = "VM.Standard.E6.Flex"
node_shape_ocpus      = 2
node_shape_memory_gbs = 16
node_pool_size        = 2
max_pods_per_node     = 31
node_architecture     = "amd64"

# Submit with: ./operator/run-example.sh --parallelism 4 --architecture amd64
