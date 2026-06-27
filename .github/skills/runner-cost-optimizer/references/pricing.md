# Pricing model & estimates

> [!IMPORTANT]
> Every monetary figure this skill prints is an **estimate**. ACI billing,
> meters and regional rates change over time. Use the numbers to **prioritize**,
> then confirm against the Azure Pricing Calculator / your invoice before acting.

## How ACI is billed

Azure Container Instances bills per **vCPU-second** and **GB-second** for the
time a container group is **running**. A self-hosted runner container with
`--restart-policy Always` (including ephemeral runners that exit-and-restart to
wait for the next job) is effectively running ~24/7, so it is billed ~24/7.

```
monthly_cost = (vCPU × vcpu_second_rate + memGB × mem_gb_second_rate)
               × seconds_per_month            # default 2,628,000 (730 h)
```

## Rate sources (`pricing_source`)

| Source | How | When |
|--------|-----|------|
| `static-default` | documented East US Linux approximations | default |
| `override` | `--vcpu-rate` / `--mem-rate` | explicit flags win |
| `live-retail-api` | public **Azure Retail Prices API** (`prices.azure.com`, no auth) | `--live-prices` |
| `static-fallback` | static defaults after a live fetch failure | `--live-prices` fails |

Default approximations (East US, Linux, per second):

| Rate | Default |
|------|--------:|
| vCPU-second | `$0.0000135` |
| GB-second | `$0.0000015` |

So a **2 vCPU / 4 GB always-on** runner ≈ **$86.7/mo**; the 11-runner fleet ≈
**$950/mo**. Override or use `--live-prices` for sharper numbers.

## Utilization

`utilization% = busy-minutes-per-day ÷ 1440`. Busy minutes come from each
runner's mapped repo job history (`gh api runs`): per run,
`updated_at − run_started_at`; summed and divided by the observed span in days.
A runner doing 40 min of jobs/day is ~2.8% utilized but billed 100% of the day —
the core inefficiency this skill surfaces.

## Recommendation thresholds (tunable)

| Flag | Default | Meaning |
|------|--------:|---------|
| `--baseline-cpu` / `--baseline-mem` | `1.0` / `2.0` | right-size target |
| `--low-util` | `15%` | below → scale-to-zero candidate (R2) |
| `--very-low-util` | `10%` | below → ARC migration candidate (R3) |
| `--high-util` | `60%` | at/above → reserved-instance note (R4) |
| `--offhours-save` | `0.60` | fraction of cost saved by off-hours stop |

## Fleet "potential savings" model

For each runner the engine takes the **single largest applicable operational
lever** and sums them (conservative — it does not stack levers, and it excludes
right-size for heavily-utilized runners which likely need their cores).
Reserved-instance discounts (R4) are shown as **notes**, not counted in the
operational potential, because they require a 1–3 year commitment.

## Normalized document schema (engine input)

```jsonc
{
  "meta": {
    "region": "eastus",
    "rates": { "vcpu_second": 0.0000135, "mem_gb_second": 0.0000015, "source": "static-default" },
    "seconds_per_month": 2628000,
    "baseline_cpu": 1.0, "baseline_mem_gb": 2.0,
    "low_util_pct": 15.0, "very_low_util_pct": 10.0, "high_util_pct": 60.0,
    "offhours_save_frac": 0.60
  },
  "containers": [
    { "name": "ghrunner-aci-01", "cpu": 2.0, "memory_gb": 4.0,
      "running": true, "repo": "owner/name", "util_pct": 3.2 }
  ]
}
```
