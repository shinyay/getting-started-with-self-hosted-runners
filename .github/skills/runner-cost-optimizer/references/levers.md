# Savings levers

The engine emits one recommendation per applicable lever. Status: `OK`
(no change), `REVIEW` (validate then apply), `SAVE` (clear operational saving),
`INFO` (note / requires commitment). This skill is **read-only** — it prints the
levers and estimates; you apply them with the related operations skills.

## R1 · Right-size (REVIEW)

Reduce over-provisioned vCPU/memory to the baseline.

- **When**: `cpu > --baseline-cpu` or `memGB > --baseline-mem`.
- **Saving**: `current − resized` monthly cost.
- **Caveat**: validate the workload first — Docker builds / large compilations
  may genuinely need the cores. Excluded from fleet *potential* for heavily
  utilized runners.
- **Apply**: recreate the ACI runner at the smaller size (`ghrunner-ops` A1/A2,
  `ghrunner-provision`). ACI size is fixed at create time — you redeploy.

## R2 · Scale-to-zero off-hours (SAVE)

Stop idle runners outside working hours.

- **When**: `utilization% < --low-util`.
- **Saving**: `cost × --offhours-save` (default 60%).
- **Apply**: schedule `az container stop` / `az container start` (e.g., a cron /
  Logic App / GitHub Actions schedule). See `docs/14` *Auto-Shutdown Idle VMs*
  for the VM equivalent (`az vm auto-shutdown`, `az vm deallocate`).

## R3 · Migrate to ARC (SAVE, structural)

Move low-frequency repos to AKS + Actions Runner Controller, which scales runner
pods to **zero** when idle and back up on demand.

- **When**: `utilization% < --very-low-util`.
- **Saving**: up to `cost × (1 − utilization)` (you pay ~only while jobs run),
  minus AKS control-plane / node overhead.
- **Apply**: `arc-ops` (`arc-up.sh`), with `github-app-runner-auth` for App auth.
  Best when several low-use repos share one autoscaling cluster.

## R4 · Reserved / commitment (INFO)

For steady, highly-utilized always-on runners, a 1–3 year commitment cuts the
rate.

- **When**: `utilization% ≥ --high-util`.
- **Saving**: ~30% (1-year) to ~55% (3-year). Shown as a note (requires
  commitment; not counted in operational potential).
- **Apply**: Azure Reservations / savings plans (see `docs/14` *Reserved
  Instances*).

## Platform levers (catalog — VM & AKS)

From `docs/14-advanced-enterprise.md`:

| Lever | Platform | Note |
|-------|----------|------|
| **Spot VMs** | VM | up to 90% off for interruptible jobs (linting/tests), evictable — `vm-runner-ops` |
| **Auto-shutdown** | VM | `az vm auto-shutdown` + deallocate idle |
| **Reserved instances** | VM/ACI | 24/7 steady-state runners |
| **Cluster autoscaler → 0** | AKS/ARC | `--min-count 0`; native idle scale-down |
| **Spot node pools** | AKS/ARC | runner pods on Spot nodes |
| **Right-sizing guide** | VM | size table in `docs/14` |

## Mapping to skills

| Lever | Apply with |
|-------|------------|
| R1 right-size | `ghrunner-ops`, `ghrunner-provision` |
| R2 scale-to-zero | schedule `az container stop/start`; `vm-runner-ops` for VMs |
| R3 ARC migration | `arc-ops`, `github-app-runner-auth` |
| Utilization context | `runner-fleet-health` (H6 utilization) |
