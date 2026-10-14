# Financial examples and market-risk grids

The project uses synthetic inputs only. The examples demonstrate numerical methods and cloud execution patterns; they are not market data, a valuation control, or a production risk model.

## Included derivative examples

| Input | Product | What it demonstrates |
|---|---|---|
| `sample-simulation.json` | European call | Baseline discounted terminal payoff. |
| `european-put.json` | European put | Put payoff under the same market model. |
| `cash-digital-call.json` | Cash-or-nothing digital call | A discontinuous payoff and its higher simulation variance. |
| `asian-call.json` | Arithmetic-average Asian call | A path-dependent payoff using all monitoring steps. |
| `up-and-out-call.json` | Up-and-out barrier call | Path maximum monitoring and knock-out behaviour. |

All examples use geometric Brownian motion, antithetic paths, a fixed seed, and a 95% confidence interval. `product_type` selects the payoff:

```text
european | cash_digital | asian_arithmetic | up_and_out | down_and_out
```

Barrier products require a positive `barrier`. Cash-digital products require a positive `cash_payoff`. The arithmetic Asian average uses one observation after each simulation step; it does not include the initial spot observation.

Run any example through the private operator:

```bash
./operator/run-example.sh --spec examples/asian-call.json --parallelism 4
```

For a European option, add an analytic Black-Scholes comparison to a model-validation notebook or test suite. Treat the Monte Carlo confidence interval as a numerical sampling check, not as evidence that the market inputs are correct.

## Market-risk grid

`examples/grids/market-risk-grid.json` expands a 3-by-3 spot/volatility sensitivity grid into nine reproducible European-call runs. Every scenario uses the same random seed, which supports more stable *relative* scenario comparisons through common random numbers. Each scenario still has a unique run ID and immutable result prefix.

Submit the grid without a queue first:

```bash
./operator/run-grid.sh --parallelism 4
./operator/grid-status.sh --grid-id market-risk-demo
```

For a queue-managed demonstration, install and configure Kueue as a platform-owned component, apply `examples/scheduling/kueue-queues.yaml` after adapting its quota, then submit:

```bash
./operator/run-grid.sh \
  --parallelism 4 \
  --queue-name monte-carlo-grid
```

The grid launcher submits Jobs without waiting for each one. Kueue decides when queued Jobs are admitted; `operator/grid-status.sh` shows Jobs, Pods, and Kueue Workloads when the Kueue API is present.

