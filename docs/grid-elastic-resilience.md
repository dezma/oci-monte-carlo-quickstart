# Grid scheduling, elastic capacity, and worker recovery

These demonstrations are opt-in. The standard quickstart remains a small, direct Indexed Job; it does not install a queue controller or alter OKE capacity automatically.

## Queue-managed grid scheduling

Kueue is the recommended optional queue layer when several people or grids share the same batch pool. The platform team installs a Kueue release compatible with the selected OKE version. A `LocalQueue` is namespace-scoped and points to a cluster-wide `ClusterQueue`, which defines CPU and memory admission quota.

1. Review and adapt `examples/scheduling/kueue-queues.yaml` for the worker-node labels, target namespace, and approved CPU/memory quota.
2. Apply it using a Kubernetes administrator context.
3. Submit `operator/run-grid.sh --queue-name monte-carlo-grid`.
4. Inspect queued or admitted work with `operator/grid-status.sh --grid-id market-risk-demo`.

The chart adds the Kueue queue label only when `--queue-name` is given. A regular `run-example.sh` invocation therefore remains independent of Kueue.

## Elastic managed-node capacity

Use a dedicated managed OKE node pool for risk-batch work. Keep a small non-autoscaled pool for system services, and label the batch pool with `workload.oracle.com/monte-carlo=true`. Configure the OKE Cluster Autoscaler for that batch pool with a conservative minimum and a finite maximum; the platform-managed autoscaler requires its own reviewed OCI authorization to adjust node pools.

For a demonstration:

1. Start the batch pool at its minimum size.
2. Use a grid whose aggregate CPU/memory **requests** exceed the pool's initial capacity.
3. Submit the grid through Kueue or directly.
4. Watch pending Pods and the Cluster Autoscaler events until nodes join the pool.
5. Record queue wait, node launch time, pod runtime, and total worker seconds as separate measures.
6. Confirm the pool returns toward its configured minimum after Jobs finish.

Use virtual nodes only for a separate serverless-burst demonstration. They are not appropriate for comparing named Compute shapes because capacity is abstracted from the workload.

## Worker-recovery demonstration

The normal chart deliberately has `backoffLimit: 0`. To demonstrate recovery, submit a dedicated test run with the resilience overlay:

```bash
./operator/run-example.sh \
  --spec examples/asian-call.json \
  --parallelism 4 \
  --values helm/monte-carlo/examples/resilience-values.yaml \
  --no-wait
```

Identify one Pod from that test Job, then delete only that test Pod. Kubernetes creates a replacement for the same completion index. The overlay permits two retries per index, ignores disruption-targeted Pod failures, and fails fast when the simulator returns exit code `2` for an invalid input.

```bash
kubectl -n monte-carlo get pods -l monte-carlo.oracle.com/run-id='<run-id>'
kubectl -n monte-carlo delete pod '<one-test-pod>'
```

The worker writes result objects with a write-once precondition. If a Pod is interrupted after a successful write, a retry verifies the existing immutable partition content before treating it as complete. The final reducer still requires exactly one valid partial result for every expected index.

Do not drain production nodes or terminate worker instances to demonstrate this behaviour. Use a short-lived dedicated test run and remove its Helm release after reviewing the events and result objects.
