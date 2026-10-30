# Insurance savings example

This example uses fictional numbers to show how a savings policy can behave under many possible investment and life-event outcomes. It is intended to be easy to change: edit the JSON input, run it again, and compare the results.

## What the simulation represents

The example is a simplified ten-year savings policy with insurance cover.

1. The customer makes one initial payment and then monthly payments.
2. The money is placed in an investment account. Its value can go up or down, and a management fee is taken over time.
3. Every month, the model considers whether the customer dies or chooses to withdraw. Either event ends the policy and causes a payment.
4. If the policy lasts ten years, the customer receives the higher of the investment-account balance and a promised minimum amount.

One simulation is one possible story for one customer. The model runs many such stories, then averages the payments and counts how often each ending occurs.

## Input

The complete input is [unit-linked-endowment.json](../examples/insurance-savings/unit-linked-endowment.json). The path uses a monthly projection, so `projection.steps_per_year` is intentionally fixed at `12`.

| Section | Key fields | Plain-language meaning |
|---|---|---|
| `projection` | `term_years`, `discount_rate` | How long the policy lasts and how later payments are converted into their equivalent value today. |
| `policy` | premiums, guarantee, death benefit, surrender charge | What the customer pays, the minimum promised at the end, the death payment, and the withdrawal deduction. |
| `fund` | account value, return, volatility, fee | Starting savings balance, assumed investment growth, how much that growth can vary, and the annual fee. |
| `policyholder_behavior` | lapse rate, stress multiplier | How often customers are assumed to withdraw early. The multiplier makes that assumption lower or higher for a stress test. |
| `mortality` | base mortality, ageing multiplier | How often a death payment is assumed to occur and how that chance changes over time. |
| `expenses` | monthly policy expense | The running cost of keeping an active policy. |

`fund.initial_account_value` is the post-allocation account value at issue. In this example it corresponds to the initial premium; it is not added to the account a second time. The initial premium remains a policy cash inflow in the output.

Each month, an active policy receives a payment where applicable, the investment balance changes, and the running cost is recorded. The model then checks first for death and then for an early withdrawal. A withdrawal pays the account balance less the withdrawal deduction. At the end of the term, the payment is `max(account value, maturity guarantee)`: the better of the savings balance and the promised minimum.

## Run it

From the private operator VM after the normal image build, pull-secret, and runtime-baseline steps:

```bash
./operator/run-insurance-savings.sh --parallelism 4
```

You can copy the input, change a value, and run your version with the normal command:

```bash
./operator/run-example.sh \
  --spec /path/to/your-insurance-input.json \
  --parallelism 8
```

`--parallelism` changes how many parts run at the same time. It does not change the number of simulated policy stories. Increase `simulations` when you want a steadier average.

## Output and interpretation

The result is JSON. All monetary amounts use the same unit as the input, such as dollars, shillings, or euros.

| Output | Interpretation |
|---|---|
| `expected_pv_benefits` | Average value today of all payments to customers: death, withdrawal, and end-of-term payments. |
| `expected_pv_premiums` | Average value today of the initial and monthly payments received from customers. |
| `expected_pv_expenses` | Average value today of the running cost of active policies. |
| `net_liability` | `benefits + expenses - premiums`. A positive number means payments and costs are greater than premiums under these assumptions. |
| `net_liability_confidence_interval` | A range showing how much the net-liability average could move because the simulation uses random outcomes. It is not a range of possible customer payments. |
| `expected_maturity_account_value` | Average investment balance for policies that reach the ten-year end date. |
| `maturity_probability` | Share of simulated policies that reach the end date. |
| `surrender_probability` | Share of simulated policies where the customer withdraws early. |
| `death_claim_probability` | Share of simulated policies that end with a death payment. |
| `guarantee_binding_probability` | Share of all policies where the promised minimum is higher than the investment balance at the end date, so a top-up is needed. |
| `input_sha256` | A fingerprint of the exact input used for the run. |
| `total_worker_seconds` | Total time spent doing calculation work across all workers. |

The three ending probabilities—maturity, withdrawal, and death—add up to one. The guarantee-binding probability is separate because it only applies to policies that reach the end date.

## Stress grid

The included grid runs nine variations of the same policy: three levels of investment uncertainty multiplied by three levels of early-withdrawal behaviour. It helps answer simple questions such as: *what changes if investments become less predictable, or more customers withdraw early?*

```bash
./operator/run-insurance-grid.sh --parallelism 4
./operator/grid-status.sh --grid-id insurance-savings-stress
```

The grid submits all nine scenarios, then lets you review each completed result independently:

```bash
./operator/aggregate-insurance-savings-results.sh \
  --run-id '<completed-run-id>' \
  --expected-partitions 4 \
  --confidence 0.95
```

For a larger grid, increase `--max-scenarios` only after deciding how many runs and how much capacity you want to use. The same scheduling, elastic-capacity, and recovery guidance in [Grid, elastic capacity, and resilience](grid-elastic-resilience.md) applies to this workload.
