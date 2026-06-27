# Continuous Monitoring (opt-in, costed)

The on-demand `health.sh` snapshot is free and read-only. For **continuous**
monitoring with alerting, `monitor-up.sh` provisions Azure Monitor, and
`monitor-down.sh` tears it down to **return cost to zero**.

> [!WARNING]
> `monitor-up.sh` creates **billable** resources (a Log Analytics workspace has
> ingestion + retention cost). Always tear down with `monitor-down.sh` when you
> no longer need it. The scripts are built around create → use → delete so cost
> is bounded.

## What `monitor-up.sh` provisions

All cost-bearing resources go into a **dedicated** resource group
(`rg-runner-monitor` by default) so teardown is a single, safe RG delete:

| Resource | Where | Purpose |
|----------|-------|---------|
| Log Analytics workspace (`ghrunner-logs`) | `rg-runner-monitor` | metrics/logs sink + KQL |
| Action group (`ghrunner-health-ag`) | `rg-runner-monitor` | alert notification target |
| Metric alert (`ghrunner-cpu-alert`) | `rg-runner-monitor` | fires on sustained ACI CPU > 80% |
| Diagnostic settings (`ghrunner-health-diag`) | **on each target ACI** | streams ACI metrics → workspace |

```bash
S=.github/skills/runner-fleet-health/scripts
SUB=<subscription-id>

# Monitor the whole fleet RG:
bash "$S/monitor-up.sh" --subscription "$SUB" --target-rg ghrunner-rg --yes

# Monitor a single container, with email alerts:
bash "$S/monitor-up.sh" --subscription "$SUB" \
  --target-rg ghrunner-rg --target-container ghrunner-aci-01 \
  --action-email you@example.com --yes
```

## Teardown (return cost to zero)

```bash
bash "$S/monitor-down.sh" --subscription "$SUB" \
  --monitor-rg rg-runner-monitor --target-rg ghrunner-rg --yes
```

`monitor-down.sh`:
1. Deletes the `ghrunner-health-diag` diagnostic settings from the target ACI
   (these live **on the container resource**, not in the monitor RG, so they
   must be removed explicitly — otherwise they dangle when the workspace is
   gone).
2. Deletes `rg-runner-monitor` wholesale (workspace + action group + alert).

> [!IMPORTANT]
> **Safety guard:** `monitor-down.sh` refuses to delete a `--monitor-rg` equal
> to the target/fleet RG (`ghrunner-rg`). The dedicated-RG model guarantees the
> ACI runners are never touched — only their diagnostic settings are detached.

## Notes & caveats

- **ACI diagnostic settings are best-effort.** ACI's Azure Monitor integration
  is narrower than AKS Container Insights; `monitor-up.sh` attaches `AllMetrics`
  and continues (with a warning) if a category is unsupported. Native ACI log
  shipping can alternatively be set at `az container create` time via
  `--log-analytics-workspace` (requires recreating the container).
- **Never run `az account set`** — `~/.azure` may be shared; the scripts pass
  `--subscription`.
- For richer dashboards/queries, see `docs/12-monitoring-maintenance.md` §3–4.
