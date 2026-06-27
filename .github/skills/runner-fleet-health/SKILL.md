---
name: runner-fleet-health
license: MIT
description: >-
  Monitor and check the health of the self-hosted GitHub Actions runner fleet
  (ACI, plus the VM and AKS/ARC alternatives). Use when you need an on-demand
  health snapshot or to set up continuous monitoring: verify runner
  online/offline/busy ratios, measure job queue depth and pickup wait time,
  check recent job success rate, detect container restart spikes and image
  drift, and get a HEALTHY/DEGRADED/UNHEALTHY scorecard with an exit code for
  cron/CI gating. The read-only snapshot never mutates anything. Optional opt-in
  continuous monitoring provisions Azure Monitor (Log Analytics workspace,
  action group, ACI metric alert, diagnostic settings) into a dedicated resource
  group and tears it down to zero out cost. Operationalizes
  docs/12-monitoring-maintenance.md. Pairs with ghrunner-ops, ghrunner-triage,
  runner-hardening-audit, arc-ops. Trigger phrases: runner health, fleet health,
  monitor runners, runner monitoring, queue wait time, runner capacity, runner
  observability, Azure Monitor runners.
---

# runner-fleet-health — Runner Fleet Health & Monitoring

Answers **"is the fleet healthy and sized right?"**. Two modes:

- **(a) On-demand snapshot** — read-only `health.sh`: a HEALTHY/DEGRADED/
  UNHEALTHY scorecard across runner availability, queue/wait, job success,
  restarts and image drift. Free, never mutates.
- **(b) Continuous monitoring** — opt-in, **costed** `monitor-up.sh` /
  `monitor-down.sh`: provisions Azure Monitor into a dedicated RG and tears it
  down to return cost to zero.

Signals & thresholds: **[references/signals.md](./references/signals.md)**.
Continuous monitoring: **[references/continuous-monitoring.md](./references/continuous-monitoring.md)**.
This operationalizes **`docs/12-monitoring-maintenance.md`**.

## When to Use This Skill

- Quick "is my fleet healthy right now?" check before/after operations
- Spot capacity gaps (queued jobs, slow pickup) and degraded success rates
- Gate a cron/CI job on fleet health (`--strict` exit code)
- Stand up (and later tear down) Azure Monitor alerting for the fleet

## What It Measures

| Signal | Reads |
|--------|-------|
| **H1** Runner availability | online/offline/busy runners vs the ledger |
| **H2** Queue & wait | queued runs + pickup latency (`run_started_at − created_at`) |
| **H3** Job success rate | recent run conclusions |
| **H4** Restart spike | non-ephemeral ACI `restartCount` |
| **H5** Image drift | mixed/unpinned images across the fleet |
| **H6** Utilization | idle capacity (all-busy → INFO) |

Verdict: any `CRIT` → **UNHEALTHY**; any `WARN` → **DEGRADED**; else **HEALTHY**.

## Prerequisites

- `gh` CLI authenticated as the fleet owner (**`shinyay`**) — runner & run data
- `az` CLI able to reach **`ghrunner-rg`** — ACI runtime state (mode b: provisioning)
- `python3` (standard library only)

## Guardrails

> [!IMPORTANT]
> The snapshot is read-only. Continuous monitoring is opt-in and **billable**.

- **(a) `health.sh` never mutates.** Suggested actions are printed only.
- **(b) `monitor-up.sh` creates billable resources** — always `monitor-down.sh`
  when done. Everything lives in a dedicated RG (`rg-runner-monitor`) for a
  one-shot safe teardown.
- **`monitor-down.sh` refuses to delete `ghrunner-rg`** (or any RG equal to the
  target). It only detaches diagnostic settings from the ACI, never the runners.
- **Never run `az account set`** — pass `--subscription <id>`.
- **Do not commit reports** (`.gitignore` excludes `reports/`, `*.health.*`).
  Never commit `resume` or `*.pem`.

## The Flow

### Step 1 — Choose a mode (menu)

Use **`ask_user`** to offer: **Snapshot (read-only)** · **Monitor up (costed)**
· **Monitor down (teardown)**.

### Step 2a — Snapshot

```bash
S=.github/skills/runner-fleet-health/scripts
bash "$S/health.sh" -g ghrunner-rg --subscription <SUB> --fleet      # whole fleet
bash "$S/health.sh" --repo OWNER/REPO                                # one repo
bash "$S/health.sh" -g ghrunner-rg --subscription <SUB> --strict     # cron gate
```

Present the scorecard (CRIT → WARN → INFO) and hand failing signals to the
related skill (see [signals.md](./references/signals.md)).

### Step 2b — Continuous monitoring (costed, opt-in)

```bash
bash "$S/monitor-up.sh"   --subscription <SUB> --target-rg ghrunner-rg --yes
# ... later ...
bash "$S/monitor-down.sh" --subscription <SUB> --monitor-rg rg-runner-monitor --target-rg ghrunner-rg --yes
```

Confirm cost is back to zero (the monitor RG is deleted). See
[continuous-monitoring.md](./references/continuous-monitoring.md).

## Scripts

| Script | Role | I/O |
|--------|------|-----|
| `scripts/collect-health.sh` | Live read-only collectors (`az`/`gh`) → JSON | live |
| `scripts/normalize_health.py` | Pure transform: raw JSON → normalized doc | pure |
| `scripts/health_rules.py` | Pure rule engine → health scorecard | pure |
| `scripts/health.sh` | Snapshot orchestrator, exit code | live |
| `scripts/monitor-up.sh` | (b) Provision Azure Monitor (dedicated RG) | live, costed |
| `scripts/monitor-down.sh` | (b) Teardown → cost zero (guards `ghrunner-rg`) | live |
| `scripts/test_health_rules.py` | Offline unit tests (HEALTHY/DEGRADED/UNHEALTHY) | pure |

## Verify

```bash
S=.github/skills/runner-fleet-health/scripts
python3 "$S/test_health_rules.py"                       # offline unit tests
python3 "$S/health_rules.py" "$S/fixtures/healthy.json"   # ✅ HEALTHY
python3 "$S/health_rules.py" "$S/fixtures/degraded.json"  # ⚠️ DEGRADED
python3 "$S/health_rules.py" "$S/fixtures/unhealthy.json" # ❌ UNHEALTHY
```

## Related Skills

- **ghrunner-ops** — fleet inventory & lifecycle (fix capacity/restarts)
- **ghrunner-triage** — root-cause failed jobs (H1/H3/H4)
- **runner-hardening-audit** — security posture sibling (shares image-drift)
- **arc-ops** — AKS+ARC autoscaling (H2 capacity)
- Ledger: **`docs/runner-registry.md`** · Doc: **`docs/12-monitoring-maintenance.md`**
