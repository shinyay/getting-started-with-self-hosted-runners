# Health Signals — thresholds & interpretation

The engine (`scripts/health_rules.py`) reads a normalized JSON document and emits
one of `OK`, `WARN`, `CRIT`, `INFO` per signal. Overall verdict: any `CRIT` →
**UNHEALTHY**; else any `WARN` → **DEGRADED**; else **HEALTHY**.

Exit code: UNHEALTHY → non-zero; DEGRADED → non-zero only with `--strict`;
HEALTHY → 0. The tool is **read-only** — suggested actions are printed only.

## Signals

| ID | Signal | OK | WARN | CRIT |
|----|--------|----|------|------|
| **H1** | Runner availability (per repo) | ≥1 online, none offline | some offline / none registered | **all runners offline** (no capacity) |
| **H2** | Queue & wait (per repo) | no queue / fast pickup | max pickup wait > `120s` | **queued with no idle runner** |
| **H3** | Job success rate (per repo) | ≥ `80%` | `50–80%` | **< `50%`** |
| **H4** | Restart spike (per container) | ephemeral, or low count | non-ephemeral restartCount > `5` | — |
| **H5** | Image drift (fleet) | uniform tag | unpinned `:latest` present | — |
| **H6** | Utilization (per repo) | idle capacity exists | — (INFO when all busy) | — |

Thresholds live at the top of `health_rules.py` (`WAIT_WARN_S`, `SUCCESS_WARN`,
`SUCCESS_CRIT`, `RESTART_WARN`) — tune them to your SLOs.

> [!NOTE]
> Ephemeral runners (one job → exit → restart) legitimately have a high
> `restartCount`, so **H4 only flags non-ephemeral runners**. High restarts on
> ephemeral runners are normal.

## Wait time

`H2` computes pickup latency as `run_started_at − created_at` over recent runs.
A consistently high value means runners are slow to pick up jobs (capacity or
autoscaling latency). A queued run with **no idle runner** is a hard capacity
gap → CRIT.

## Normalized document schema (engine input)

```jsonc
{
  "meta": { "expected_runners": 11 },              // from the registry ledger
  "containers": [                                   // ACI side (from -g)
    { "name": "ghrunner-aci-01", "state": "Running", // az container show
      "restart_count": 9, "ephemeral": true,
      "image_tag": "v0.6.0", "repo": "owner/name" }
  ],
  "repos": [                                        // GitHub side (--repo/--fleet)
    { "full_name": "owner/name",
      "runners": [{ "name": "r1", "status": "online", "busy": false }],
      "recent_runs": [
        { "status": "completed", "conclusion": "success",
          "created_at": "…Z", "run_started_at": "…Z" }
      ] }
  ]
}
```

## Relationship to other skills

| Signal | Hand off to |
|--------|-------------|
| H1 offline / H4 restart | `ghrunner-triage` (why), then `ghrunner-ops` (fix) |
| H2 capacity gap | `ghrunner-ops` / `arc-ops` (add runners / raise maxRunners) |
| H3 low success | `ghrunner-triage` |
| H5 image drift | `ghrunner-image-release`, `runner-hardening-audit` (A1/A5) |

## Sample KQL (with continuous monitoring)

When `monitor-up.sh` is active, the Log Analytics workspace receives ACI
metrics. Example queries (see also `docs/12-monitoring-maintenance.md`):

```kusto
// Container CPU over the last hour
AzureMetrics
| where ResourceProvider == "MICROSOFT.CONTAINERINSTANCE"
| where MetricName == "CpuUsage"
| summarize avg(Average) by Resource, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```
