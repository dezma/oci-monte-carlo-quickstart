# High-cost profile. Confirm OKE support, capacity, quota, and commercial approval before use.
node_shape            = "BM.HPC.E5.144"
node_shape_ocpus      = null
node_shape_memory_gbs = null
node_pool_size        = 1
max_pods_per_node     = 31
node_architecture     = "amd64"

# Submit with: ./operator/run-example.sh --parallelism 32 --architecture amd64
