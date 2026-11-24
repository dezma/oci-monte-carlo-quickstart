# Optional observability

Install the observability stack when you need to inspect worker CPU, memory,
CPU pressure, throttling, pod state, or File Storage mount behaviour during a
benchmark. It is optional so the default runtime remains a small and
repeatable baseline.

The stack is private and includes Prometheus, Grafana, kube-state-metrics, and
node-exporter. Grafana is exposed only through a port-forward from the private
operator; the installation does not create a public service or ingress.

## Install

Run this before starting a comparison and leave it installed for every profile
in that comparison:

```bash
./operator/install-observability.sh --retention 7d
```

Use a chart version when a release process requires a pinned dependency:

```bash
./operator/install-observability.sh \
  --retention 7d \
  --chart-version <approved-kube-prometheus-stack-version>
```

## Check the stack

```bash
./operator/observability-status.sh
```

## Open Grafana privately

```bash
./operator/open-grafana.sh
```

The command prints the local URL and Grafana password, then keeps a private
port-forward open on the operator VM. To use a browser on your workstation,
keep that command running and start a local SSH forward through the existing
Managed SSH Bastion session. Add `-N -L 3000:127.0.0.1:3000` to the SSH command
shown for that session, then browse to `http://127.0.0.1:3000`. This reaches
Grafana only through the operator loopback interface; do not create a public
load balancer or ingress.

## Useful signals during a benchmark

- `container_cpu_usage_seconds_total`: CPU consumed by a simulator container.
- `container_cpu_cfs_throttled_seconds_total`: time blocked by a CPU limit.
- `container_memory_working_set_bytes`: active memory in use.
- `kube_pod_status_phase`: Pod state and completion behaviour.
- `kube_persistentvolumeclaim_status_phase`: FSS claim state.

A `Bound` claim shows the Kubernetes binding, not a successful NFS mount or write on a particular node. Use the [worker preflight and operator mount checks](fss-result-delivery.md) to verify the data path. The suite JSON/CSV files are benchmark outputs, not Prometheus metrics.

Use the same observability setting, retention, worker count, and benchmark
image digest for each profile in one comparison.
