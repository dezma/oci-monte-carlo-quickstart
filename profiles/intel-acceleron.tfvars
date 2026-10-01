# Verify VM.Standard4.Ax.Flex is available in the selected availability domain first.
node_shape            = "VM.Standard4.Ax.Flex"
node_shape_ocpus      = 4
node_shape_memory_gbs = 32
node_pool_size        = 2
max_pods_per_node     = 31
node_architecture     = "amd64"

# Submit with: ./operator/run-example.sh --parallelism 8 --architecture amd64
