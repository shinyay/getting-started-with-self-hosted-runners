---
name: runner-cost-optimizer
license: MIT
description: >-
  Optimize and analyze the cost of the self-hosted GitHub Actions runner fleet
  (ACI, plus the VM and AKS/ARC alternatives). Use when you need a cost report or
  a right-sizing review: estimate each runner's monthly Azure cost, measure
  utilization from job history, and get prioritized savings recommendations —
  right-size over-provisioned vCPU/memory, scale-to-zero off-hours, migrate idle
  repos to ARC, or reserved/Spot — with a fleet total and a potential-savings
  figure. Read-only: it never mutates anything; recommendations are applied via
  the related ops skills. Pricing uses documented defaults, your
  --vcpu-rate/--mem-rate overrides, or live rates from the public Azure Retail
  Prices API. Operationalizes docs/14. Pairs with ghrunner-ops,
  runner-fleet-health, arc-ops, vm-runner-ops. Trigger phrases: runner cost,
  fleet cost, right-size runners, ACI cost, reduce runner cost, scale to zero,
  runner FinOps, idle runners, cost optimization, Azure cost.
---

# runner-cost-optimizer — Fleet Cost Analysis & Right-Sizing

A **read-only** FinOps report for the self-hosted runner fleet. It estimates
each runner's monthly Azure cost, measures utilization from job history, and
recommends savings levers with a fleet total and **potential-savings** figure.
The 11-runner ACI fleet is ~$950/mo always-on, so the levers matter.

Rate model & schema: **[references/pricing.md](./references/pricing.md)**.
Savings levers: **[references/levers.md](./references/levers.md)**.
This operationalizes `docs/14-advanced-enterprise.md` (Cost Optimization).

> [!IMPORTANT]
> All monetary figures are **estimates** — use them to prioritize, then confirm
> against the Azure Pricing Calculator / your invoice before acting.

## When to Use This Skill

- Produce a fleet cost report and find the biggest savings
- Spot over-provisioned (right-size) or idle (scale-to-zero / ARC) runners
- Sanity-check spend before/after scaling the fleet
- Gate a budget check in CI (`--strict` exits non-zero when a saving exists)

## What It Recommends

| ID | Lever | Trigger |
|----|-------|---------|
| **R1** | Right-size vCPU/memory | larger than baseline |
| **R2** | Scale-to-zero off-hours | utilization < `--low-util` |
| **R3** | Migrate to ARC (scale-to-zero) | utilization < `--very-low-util` |
| **R4** | Reserved / commitment (note) | utilization ≥ `--high-util` |

VM/AKS levers (Spot, auto-shutdown, autoscaler→0) are catalog-level in
[levers.md](./references/levers.md).

## Prerequisites

- `az` CLI able to reach **`ghrunner-rg`** — ACI sizing
- `gh` CLI authenticated as **`shinyay`** — job history for utilization
- `python3` (standard library only); network only for `--live-prices`

## Guardrails

> [!IMPORTANT]
> Read-only. Estimates only. Nothing is provisioned or deleted.

- **Never mutates** Azure or GitHub — recommendations are printed; apply them
  with `ghrunner-ops` / `arc-ops` / `vm-runner-ops`.
- **Figures are estimates** — clearly labelled; override rates or use
  `--live-prices` for accuracy.
- **Never run `az account set`** — pass `--subscription <id>` (placed *after*
  the command). `~/.azure` may be shared.
- **Do not commit reports** (`.gitignore` excludes `reports/`, `*.cost.*`).
  Never commit `resume` or `*.pem`.

## The Flow

### Step 1 — Choose scope (menu)

Use **`ask_user`**: **Whole fleet** (`-g ghrunner-rg --fleet`) · **One repo**
(`--repo owner/repo`) · with options (`--live-prices`, custom thresholds).

### Step 2 — Run the report (read-only)

```bash
S=.github/skills/runner-cost-optimizer/scripts

# Whole fleet, live prices, save a copy:
bash "$S/cost.sh" -g ghrunner-rg --subscription <SUB> --fleet --live-prices --out fleet.cost.md

# One repo's runner, custom right-size baseline:
bash "$S/cost.sh" -g ghrunner-rg --subscription <SUB> --repo OWNER/REPO --baseline-cpu 1 --baseline-mem 2

# Budget gate (non-zero exit if any saving exists):
bash "$S/cost.sh" -g ghrunner-rg --subscription <SUB> --fleet --strict
```

### Step 3 — Present & route (HITL)

Lead with the fleet **potential savings**, then per-runner `SAVE` → `REVIEW` →
`INFO`. Route each lever to the apply-skill (see
[levers.md](./references/levers.md)). Apply only with user approval.

## Scripts

| Script | Role | I/O |
|--------|------|-----|
| `scripts/collect-cost.sh` | Live read-only collectors (`az`/`gh`) + rates → JSON | live |
| `scripts/prices.py` | Resolve ACI rates (static / override / live retail API) | net (opt) |
| `scripts/normalize_cost.py` | Pure transform: raw JSON → normalized doc + utilization | pure |
| `scripts/cost_rules.py` | Pure engine: cost + recommendations + savings | pure |
| `scripts/cost.sh` | Orchestrator, exit code | live |
| `scripts/test_cost_rules.py` | Offline unit tests | pure |

## Verify

```bash
S=.github/skills/runner-cost-optimizer/scripts
python3 "$S/test_cost_rules.py"                              # offline unit tests
python3 "$S/cost_rules.py" "$S/fixtures/savings-fleet.json"   # 💰 SAVINGS AVAILABLE
python3 "$S/cost_rules.py" "$S/fixtures/optimized-fleet.json" # ✅ OPTIMIZED
```

## Related Skills

- **runner-fleet-health** — H6 utilization is the same signal, from the ops side
- **ghrunner-ops** / **ghrunner-provision** — right-size (recreate ACI)
- **arc-ops** / **github-app-runner-auth** — ARC scale-to-zero migration
- **vm-runner-ops** — VM Spot / auto-shutdown / reserved
- Doc: **`docs/14-advanced-enterprise.md`** · Ledger: **`docs/runner-registry.md`**
