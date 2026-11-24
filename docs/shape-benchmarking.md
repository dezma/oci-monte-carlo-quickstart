# Shape benchmarking with the insurance-savings workload

This guide compares the throughput of OCI Compute shapes using the synthetic insurance-savings model. The primary measurement uses a strict OCI-OCPU contract: the same worker CPU and memory reservation, node count, input, image digest, and host placement for every profile.

The primary strict benchmark submits one warm-up run and seven measured runs by default. The optional application-policy benchmark uses one warm-up and five measured runs. Every run uses an immutable container-image digest, a fixed random seed, fixed simulation input, and the normal write-once result and reducer path. Warm-up data is retained for troubleshooting but excluded from the reported medians.

## Choose a fair comparison

Keep these controls identical for every profile:

- the benchmark spec, image digest, parallelism, OCPU and memory per node, node count, OKE version, node image, region, availability domain, and runtime values;
- the same number of idle, dedicated worker nodes; and
- no Kueue queue during the measurement. Queue waiting and autoscaling are useful operational metrics, but they are not CPU-shape throughput.

Use a separate benchmark for each shape. For example, compare AMD E5 Flex, E6 Flex, E6 Acceleron, Intel Optimized3 Flex, Intel Acceleron, and A4 Acceleron at the same OCPU and memory allocation. A managed-node shape must be available, supported by the selected OKE version, and paired with a node image returned by `provisioning/list-oke-options.sh` before it is provisioned.

Intel and AMD use `amd64`; Ampere uses `arm64`. Before comparing both architectures, publish a multi-architecture image and confirm that `.mcqs-image.env` contains its immutable manifest digest:

```bash
./operator/build-and-push.sh --multi-arch
```

If a single-architecture image is used instead, rebuild and publish the equivalent application image for the architecture under test. Do not change application dependencies, the simulation input, or the number of paths between profiles.

## Start with the strict comparison

Run every selected managed profile as one detached, sequential suite:

```bash
./operator/run-strict-ocpu-suite.sh \
  --background \
  --parallelism 6 \
  --warmup-runs 1 \
  --measured-runs 7
```

The suite validates the FSS mount and strict resource reservation for each
profile before timing it. It writes one report per profile plus a consolidated
JSON and CSV summary. Install the optional private observability stack before
starting the suite when CPU, memory, throttling, or FSS telemetry is needed;
see [Optional observability](observability.md). Follow or stop it with the
standard suite commands:

```bash
./operator/benchmark-suite-status.sh --suite-id <suite-id> --follow
./operator/stop-benchmark-suite.sh --suite-id <suite-id>
```

## Test one provisioned worker pool

Run this from the private operator VM after `doctor.sh`, `install-runtime.sh`, image publishing, and pull-secret creation have completed:

```bash
cd /home/opc/oci-monte-carlo-quickstart
source /etc/profile.d/mcqs-runtime.sh

./operator/run-benchmark.sh \
  --profile-id e6-flex \
  --architecture amd64 \
  --parallelism 4
```

The default input is [insurance-savings-throughput-50m.json](../examples/benchmarks/insurance-savings-throughput-50m.json). It projects fifty million fictional ten-year policies. This is deliberately a larger version of the same synthetic policy used in the one-million-path smoke test: every assumption and the fixed seed are unchanged, only the number of independent paths increases. At this size, simulation compute should dominate launch, scheduling, storage, and aggregation overhead on a two-node pool.

The smaller [insurance-savings-throughput.json](../examples/benchmarks/insurance-savings-throughput.json) remains available for a quick functional smoke test, while [insurance-savings-throughput-10m.json](../examples/benchmarks/insurance-savings-throughput-10m.json) is useful for a shorter benchmark preflight. Select either explicitly with `--spec` when the full fifty-million-path run is not appropriate.

### Run a strict OCI-OCPU-normalized hardware benchmark

The normal benchmark measures the quickstart's default application resource policy. Use the strict benchmark when the question is instead: **how much work does each shape deliver with the same reserved CPU and memory capacity?**

This mode uses the one-hundred-million-policy input and a fixed resource contract for every worker:

| Control | Strict value |
|---|---|
| Selected nodes | Exactly two Ready nodes in one dedicated profile |
| Placement | Even host spread, with no one-node fallback |
| CPU request and limit | `2` Kubernetes CPU units per worker |
| Memory request and limit | `4Gi` per worker |
| Input | `insurance-savings-throughput-100m.json` |
| Repetitions | One warm-up and seven measured runs by default |

The project calls this **OCI-OCPU-normalized** rather than a raw physical-core benchmark. OCI processor families expose different core and thread designs, so equal configured OCPUs are a controlled capacity allocation, not a claim that every physical core is identical.

On the standard two-node, four-OCPU benchmark pools, use six workers. This reserves three workers per node, or `6` CPU and `12Gi` on each node, leaving capacity for Kubernetes and system services:

```bash
./operator/run-strict-ocpu-benchmark.sh \
  --profile-id e6-flex
```

The wrapper discovers the profile architecture, reconciles its label and taint, checks each node's real Kubernetes allocatable CPU and memory, and stops before submission if the requested reservation cannot fit. It then calls the ordinary benchmark runner with `examples/benchmarks/strict-ocpu-values.yaml`.

To measure eight strict workers, provision two fixed-size benchmark nodes with at least five OCPUs and 40 GB memory each, then run:

```bash
./operator/run-strict-ocpu-benchmark.sh \
  --profile-id e6-flex \
  --parallelism 8
```

Use the same node count, OCPU value, memory value, image digest, and worker count for every profile. Do not enable autoscaling for this test. The wrapper intentionally requires exactly two eligible nodes, so a scale-out or scale-in cannot silently change the capacity basis.

### Deterministic worker placement

`run-benchmark.sh` now enables a Kubernetes `topologySpreadConstraint` for every benchmark Job. It selects only partitions from that Job, spreads them by `kubernetes.io/hostname`, uses `maxSkew: 1`, and requires two eligible worker nodes (`minDomains: 2`). With four partitions and two matching nodes, this produces a 2/2 placement. It prevents a one-node run or a 3/1 placement from silently becoming a shape-comparison result.

Consequently, the selected profile must have at least two Ready, schedulable nodes before the benchmark begins. If capacity is intentionally limited to one node—for example, a single-node scaling experiment—use `--no-topology-spread`; do not compare that result with the standard two-node shape benchmark.

Every warm-up and measured Job receives a short digest derived from its benchmark-series ID in the Kubernetes run name. This keeps the run name below Kubernetes limits without reusing an immutable ConfigMap or Job when a profile is benchmarked more than once in an hour.

The default command creates:

```text
benchmark-results/insurance-e6-flex-<UTC timestamp>/
├── warmup-01.json
├── measured-01.json ... measured-05.json
├── benchmark-summary.json
└── benchmark-summary.csv
```

`benchmark-results/` is deliberately ignored by Git because it contains local measurement data. Copy the directory to your approved evidence store when needed.

## Compare dedicated pools in one cluster

When a cluster has more than one worker pool, each profile must have a unique label. The optional Terraform-managed profile feature creates the node pools, labels, capacity controls, and profile definition together; this is the preferred repeatable path. Manual node-pool labels remain useful for an existing cluster.

| Shape profile | Node-pool label | Architecture |
|---|---|---|
| AMD E5 Flex | `benchmark.oracle.com/profile=e5-flex` | `amd64` |
| E6 Flex | `benchmark.oracle.com/profile=e6-flex` | `amd64` |
| E6 Acceleron | `benchmark.oracle.com/profile=e6-acceleron` | `amd64` |
| Intel Optimized3 Flex | `benchmark.oracle.com/profile=intel-optimized3` | `amd64` |
| Intel Acceleron | `benchmark.oracle.com/profile=intel-acceleron` | `amd64` |
| A2 Flex | `benchmark.oracle.com/profile=a2-flex` | `arm64` |
| A4 Acceleron | `benchmark.oracle.com/profile=a4-acceleron` | `arm64` |

Apply the label as an OKE node-pool initial node label so it persists across node replacement. Confirm that it is present before a run:

```bash
kubectl get nodes -L benchmark.oracle.com/profile,kubernetes.io/arch
```

Then pin the benchmark to one pool. This example measures an x86 E6 Acceleron pool:

```bash
./operator/run-benchmark.sh \
  --profile-id e6-acceleron \
  --architecture amd64 \
  --parallelism 4 \
  --node-selector benchmark.oracle.com/profile=e6-acceleron
```

Run a separate command for every profile. Do not schedule two benchmark profiles at the same time if they share cluster control-plane, network, or storage limits.

## Run a benchmark suite in the background

When several Terraform-managed benchmark profiles are selected, use the suite runner to measure them one at a time without keeping the Bastion terminal open. It discovers the selected profiles from the operator configuration, skips a profile that does not currently have two Ready matching nodes, and keeps the same workload, image digest, parallelism, warm-up count, and measured-run count for every eligible profile.

Start all currently eligible profiles in the background:

```bash
./operator/run-benchmark-suite.sh \
  --background \
  --parallelism 4 \
  --warmup-runs 1 \
  --measured-runs 7
```

The command prints a suite ID. Follow progress from another Bastion session, or after reconnecting later:

```bash
./operator/benchmark-suite-status.sh \
  --suite-id <suite-id> \
  --follow
```

To stop a detached suite, remove only its active Job, and retain reports for
profiles that already completed:

```bash
./operator/stop-benchmark-suite.sh \
  --suite-id <suite-id>
```

To run an intentional subset, provide the profile IDs as a comma-separated list:

```bash
./operator/run-benchmark-suite.sh \
  --background \
  --profiles e5-flex,e6-flex,e6-acceleron,intel-optimized3,intel-acceleron,a4-acceleron \
  --parallelism 4 \
  --warmup-runs 1 \
  --measured-runs 7
```

The completed suite writes one consolidated report and one profile log per selected profile:

```text
benchmark-results/suites/<suite-id>/
├── suite-status.json
├── suite.log
├── e6-flex.log
├── summaries/
├── suite-summary.json
└── suite-summary.csv
```

The runner is sequential by design. Running shape profiles concurrently would make shared Kubernetes control-plane, network, storage, and registry activity part of the measurement.

For a simple quickstart cluster with one pool, no custom selector is necessary. If you already use the standard worker label, `--node-selector workload.oracle.com/monte-carlo=true` is equivalent but makes the intended target explicit.

## Run a complete scaling study

Use `run-scaling-study.sh` when the question is broader than "which shape is fastest at four workers?" The detached runner measures each selected profile one point at a time and produces a single comparison report with three views:

| View | What stays constant | What changes | Primary question answered |
|---|---|---|---|
| Strong scaling | Total simulation paths | Worker count | How much faster does one fixed workload finish as workers are added? |
| Weak scaling | Paths per worker | Worker count and total paths | Does each additional worker preserve its expected rate as workload capacity grows? |
| Throughput saturation | Derived from strong-scaling points | Worker count | At which tested worker count does end-to-end throughput peak? |

The default levels are `2,4,6,8`. Strong scaling holds the workload at 50 million paths. Weak scaling keeps 12.5 million paths per worker, so the tested totals are 25 million, 50 million, 75 million, and 100 million paths. Every point uses the same immutable image digest, benchmark profile, node capacity, FSS result path, warm-up count, and measured-run count.

Start a full study in the background. The example uses seven measured runs and three profiles; omit `--profiles` to run every Terraform-managed benchmark profile currently configured on the operator:

```bash
STUDY_ID="insurance-scaling-$(date -u +%Y%m%d%H%M%S)"

./operator/run-scaling-study.sh \
  --background \
  --study-id "$STUDY_ID" \
  --profiles e6-flex,e6-acceleron,a4-acceleron \
  --spec examples/benchmarks/insurance-savings-throughput-50m.json \
  --parallelism-levels 2,4,6,8 \
  --strong-simulations 50000000 \
  --weak-simulations-per-worker 12500000 \
  --warmup-runs 1 \
  --measured-runs 7
```

The command returns immediately. The process continues after an SSH or Bastion disconnect. Follow progress in another session, or after reconnecting later:

```bash
./operator/scaling-study-status.sh \
  --study-id "$STUDY_ID" \
  --follow
```

Add `--log` to show recent live output. To stop only the active point while retaining all completed results:

```bash
./operator/stop-scaling-study.sh --study-id "$STUDY_ID"
```

The results are written below one private local directory:

```text
benchmark-results/scaling-studies/<study-id>/
├── study-status.json
├── study.log
├── specs/
├── logs/
├── profiles/
├── points/
├── scaling-study-summary.json
└── scaling-study-summary.csv
```

With four parallelism levels, two scaling views, one warm-up, and seven measured runs, a study submits 64 benchmark Jobs per profile. Run it in the background and treat it as a planned capacity exercise. For a shorter first pass, use three levels and five measured runs:

```bash
./operator/run-scaling-study.sh \
  --background \
  --study-id "insurance-scaling-quick-$(date -u +%Y%m%d%H%M%S)" \
  --profiles e6-flex \
  --parallelism-levels 2,4,6 \
  --warmup-runs 1 \
  --measured-runs 5
```

### Read the scaling report

The report records the immutable image, input hash, node inventory, node shape, architecture, Kubernetes version, allocatable resources, p50 wall time, p95 wall time, and both wall-clock and worker-time throughput for every point.

For strong scaling, `speedup_vs_min_parallelism` compares each point with the lowest worker count, while `parallel_efficiency` compares observed speedup with ideal linear scaling. A value near `1.0` indicates that the added workers are contributing efficiently.

For weak scaling, `wall_clock_ratio_vs_min_parallelism` should remain close to `1.0`; this means a larger workload completed in approximately the same time as the baseline. `worker_throughput_ratio_vs_min_parallelism` shows whether the individual worker rate stayed stable.

`throughput_saturation` identifies the tested parallelism level with the highest end-to-end paths-per-second result. It is a workload-saturation measure, not a substitute for hardware CPU-utilization telemetry. Use OCI Monitoring or a cluster observability stack when CPU, memory, network, or FSS utilization itself is a decision criterion.

The topology-spread rule remains active for every point. On a two-node profile, the default worker levels place partitions evenly: 2 workers as 1/1, 4 workers as 2/2, 6 workers as 3/3, and 8 workers as 4/4. The higher levels are intended to expose the throughput knee. Compare only like-for-like levels across shapes, and document the configured OCPU and memory per node beside the report.

## Provision repeatable benchmark pools

To compare several shapes without recreating the cluster, use the guided **Benchmark profiles** sections in Resource Manager. Select the pools you want, enter up to two image OCIDs, and set one shared capacity envelope. No structured text or profile identifiers are required in the form.

| Resource Manager choice | Created profile | Shape | Architecture |
|---|---|---|---|
| Add AMD E5 Flex pool | `e5-flex` | `VM.Standard.E5.Flex` | `amd64` |
| Add AMD E6 Flex pool | `e6-flex` | `VM.Standard.E6.Flex` | `amd64` |
| Add AMD E6 Acceleron pool | `e6-acceleron` | `VM.Standard.E6.Ax.Flex` | `amd64` |
| Add Intel Optimized3 Flex pool | `intel-optimized3` | `VM.Optimized3.Flex` | `amd64` |
| Add Intel Acceleron pool | `intel-acceleron` | `VM.Standard4.Ax.Flex` | `amd64` |
| Add Ampere A4 Acceleron pool | `a4-acceleron` | `VM.Standard.A4.Ax.Flex` | `arm64` |

The primary worker image is reused automatically for a selected profile of the same architecture. Supply **AMD and Intel OKE image OCID** only when the primary worker is not `amd64`; supply **Ampere A4 OKE image OCID** only when the primary worker is not `arm64`. Every supplied image must match the selected full Kubernetes version.

The **Benchmark profiles — images and capacity** section applies the same OCPUs, memory, initial nodes, minimum nodes, maximum nodes, and Pod limit to every selected Flex profile. This makes a multi-shape comparison controlled by default. The initial values—4 OCPUs, 32 GB, two nodes, and a 2–4 node range—support the default two-host placement rule; they are a modest starting point, not a capacity recommendation.

For Terraform CLI, the equivalent guided configuration is straightforward:

```hcl
enable_benchmark_e6_flex          = true
enable_benchmark_e5_flex          = true
enable_benchmark_e6_acceleron     = true
enable_benchmark_intel_optimized3 = true
enable_benchmark_intel_acceleron  = true
enable_benchmark_a4_acceleron     = true

# Required here because the primary worker in this example is amd64.
benchmark_arm64_node_image_id = "ocid1.image.oc1..arm64-image-for-your-selected-oke-version"

benchmark_pool_ocpus             = 4
benchmark_pool_memory_gbs        = 32
benchmark_pool_initial_size      = 2
benchmark_pool_min_size          = 2
benchmark_pool_max_size          = 4
benchmark_pool_max_pods_per_node = 31

# Enable only when elastic capacity is part of the exercise.
enable_benchmark_cluster_autoscaler = true
```

`benchmark_node_pools_json` remains available only for advanced Terraform CLI use when a custom profile is needed beyond these six guided choices. It is intentionally not shown in Resource Manager.

The shared OCPU and memory settings give every selected Flex pool an equivalent configured capacity. The processor families have different core and thread designs, so equal OCPU configuration is not a claim of identical physical-core count. Keep the same parallelism, memory, node count, image version, and workload input when making a throughput comparison.

`initial_size` is the number of nodes created by Terraform. `min_size` and `max_size` are enforced only when `enable_benchmark_cluster_autoscaler = true`; the add-on is configured with exactly the selected benchmark pool OCIDs, so the primary worker pool remains outside autoscaling. Terraform intentionally ignores later node-count drift on these pools, because a scale-in or scale-out is the expected action of the add-on. Keep at least one ordinary pool for OKE system services and normal workload operations.

After adding or changing profile definitions, increment `operator_bootstrap_generation` in the same Terraform apply. This intentionally replaces the private operator VM so its local profile/taint configuration matches the new node pools. Recreate the OCIR pull secret and image metadata on the replacement operator before running a benchmark.

For every profile, Terraform sets `benchmark.oracle.com/profile=<profile-id>` as an OKE initial node label. It also delivers this profile's `benchmark.oracle.com/profile=<profile-id>:NoSchedule` taint intent to the operator. OKE's node-pool Terraform resource exposes initial node labels but not a persistent Kubernetes taint field. Therefore `run-benchmark.sh` automatically runs `operator/reconcile-benchmark-pools.sh` before a Terraform-defined profile run, taints all currently joined profile nodes, selects the profile label, and adds the matching Job toleration.

Run the profile with no manually repeated placement arguments:

```bash
./operator/run-benchmark.sh \
  --profile-id e6-flex \
  --architecture amd64 \
  --parallelism 8
```

The reconciliation command can also be run after planned node replacement or a scale-out event:

```bash
./operator/reconcile-benchmark-pools.sh --profile e6-flex
```

It requires operator Kubernetes access that can patch Nodes (`iam_admin` in this quickstart). For a namespace-only operator, a cluster administrator must perform the taint reconciliation. The benchmark Job itself always has the matching toleration; new autoscaled nodes retain the Terraform node-pool label and can accept the benchmark as soon as they join.

The Cluster Autoscaler add-on uses an OKE workload identity. Selecting `create_benchmark_cluster_autoscaler_workload_identity_policy` creates the narrowly conditioned policy it needs for this cluster's `kube-system/cluster-autoscaler` service account to resize node pools and their compute/network resources. OCI policy grammar names the workload subject `any-user`; the policy conditions restrict it to the exact workload type, cluster, namespace, and service account. Set the control to `false` only when an equivalent reviewed policy is managed separately. Some tenancies deliberately prohibit this policy form; in that case leave autoscaling off and use the Terraform-created initial pool size for controlled static benchmarking.

## Adjust the test size

The default fifty million paths makes launch and aggregation overhead much less significant than a one-million-path smoke test. Keep the input unchanged for a direct profile comparison. The ten-million-path input is appropriate for a short preflight; use fifty million paths for a normal shape comparison. Increase to one hundred million paths only when a longer controlled run is justified by the expected decision value, then use that same input for every profile. You can change the repetition count without changing the workload:

```bash
./operator/run-benchmark.sh \
  --profile-id e6-flex \
  --architecture amd64 \
  --parallelism 8 \
  --warmup-runs 1 \
  --measured-runs 7
```

Use `--warmup-runs 0` only when you have a reason to omit a warm-up. Do not set `--parallelism` higher than the available CPU, memory, and Pod capacity of the pool. For a scaling study, make a separate benchmark series for each parallelism level; do not compare a four-worker result with an eight-worker result as a shape-only comparison.

## Read the report

`benchmark-summary.json` contains the per-run records and these comparison measures:

| Field | Meaning | How to use it |
|---|---|---|
| `median_wall_clock_seconds` | Median elapsed time from submission to completed result aggregation for the five measured runs. | Primary end-to-end turnaround comparison; lower is better. |
| `p95_wall_clock_seconds` | Slowest-tail elapsed time among measured runs. | Shows run-to-run variability and interference. |
| `median_simulations_per_wall_second` | Paths in the selected benchmark spec divided by wall-clock seconds, then medianed across measured runs. | Primary throughput value; higher is better. |
| `median_simulations_per_worker_second` | Paths in the selected benchmark spec divided by summed worker time, then medianed. | Useful for CPU efficiency, but not a replacement for elapsed turnaround. |
| `input_sha256` | Hash of the rendered input for one submitted run. | Run IDs are made unique, so hashes can differ between launches. Compare the fixed benchmark spec, seed, simulation count, image digest, and numerical output instead. |
| `summary.net_liability` and outcome probabilities | Numerical result of the synthetic policy model. | Check they are statistically consistent across profiles; they should not be used to rank CPU shapes. |

Print the concise report:

```bash
jq '{profile_id, architecture, measured_runs, median_wall_clock_seconds, p95_wall_clock_seconds, median_simulations_per_wall_second, median_simulations_per_worker_second}' \
  benchmark-results/<benchmark-id>/benchmark-summary.json
```

The CSV has one row per warm-up or measured run and is suited to a spreadsheet or observability data source. Benchmark duration is a useful cost input, but this project does not calculate OCI cost: pool size, node billing interval, discounts, and other workload occupancy must be evaluated separately.

## Check placement and failures

While a run is active, check that all Pods landed on the intended profile and that no worker failures occurred:

```bash
kubectl -n monte-carlo get pods \
  -l monte-carlo.oracle.com/benchmark-id=<benchmark-id> \
  -o wide

kubectl -n monte-carlo get jobs \
  -l monte-carlo.oracle.com/benchmark-id=<benchmark-id>
```

If the results differ unexpectedly, discard that series and investigate node placement, pending Pods, image pulls, capacity pressure, Object Storage/API latency, and background load before rerunning. A successful benchmark is a controlled experiment, not just a completed Job.
