---
name: ghrunner-triage
license: MIT
description: >-
  Diagnose and debug why a self-hosted GitHub Actions runner job failed and recommend a
  fix. Use when a runner job errors, fails, or is stuck queued: it analyzes the
  failed-step logs and the ACI/VM/ARC runner logs, matches them against a
  failure catalog (image, auth, workflow, config, infra), and hands the fix off
  to the ghrunner-ops skill to rebuild the image or redeploy the runner.
  Read-only — never mutates infrastructure. Covers
  the ghrunner-aci fleet plus the VM and AKS+ARC runners in this repo.
  Trigger phrases: runner job failed, why did my workflow fail, runner error,
  job stuck queued, self-hosted runner failure, diagnose runner, triage runner,
  lsb_release not found, refusing to merge unrelated histories, runner offline.
---

# ghrunner-triage — Runner Job Failure Triage

Diagnose self-hosted runner job failures and recommend a remediation. This skill
is **read-only**: it identifies the root cause and **hands the fix off** to the
[`ghrunner-ops`](../ghrunner-ops/SKILL.md) skill or a cited doc. It never changes
infrastructure.

## When to Use This Skill

- A workflow job on a self-hosted runner **failed** or errored
- A run is **stuck in `queued`** and never starts
- A runner shows **Offline** or an ACI container is crash-looping
- You have a pasted error log and want to know the cause and fix

## Prerequisites

- `gh` CLI authenticated as the repo owner (e.g. `shinyay`)
- For ACI container logs: `az` reachable to `ghrunner-rg` (optional but helpful)
- Tools: `gh`; `az` for ACI; `kubectl` for ARC

## Guardrails

> [!IMPORTANT]
> This skill **diagnoses only**. It must not run fixes.

- **Read-only.** Recommend fixes; execute them via `ghrunner-ops` (`A2`/`A3`/
  `A4`/`A6`) or the cited doc — never from here.
- **Never run `az account set`** (`~/.azure` is shared); pass `--subscription`.
- **Never stage/commit/modify the untracked `resume` file.**
- **Do not echo secrets/tokens** copied from logs into your output.

## Triage Flow

### Step 1 — Identify the failure

Get the run, the failed job/step, and the `runner_name`:

```bash
REPO="owner/repo"
RUN_ID="$(gh run list --repo "$REPO" --status failure -L 1 --json databaseId --jq '.[0].databaseId')"
gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" \
  --jq '.jobs[] | select(.conclusion=="failure")
        | {job:.name, runner:.runner_name, step:(.steps[]?|select(.conclusion=="failure")|.name)}'
```

### Step 2 — Map the runner to a platform

`runner_name` like `ghrunner-aci-NN` → ACI (look it up in
`docs/runner-registry.md`). Otherwise VM or ARC. See
[references/diagnostics.md](./references/diagnostics.md).

### Step 3 — Collect evidence

Failed-step logs plus platform logs (ACI `az container logs`, VM `journalctl`,
ARC `kubectl logs`). Commands: [references/diagnostics.md](./references/diagnostics.md).

### Step 4 — Match against the failure catalog

Run the bundled script (preferred) or match by hand against
[references/failure-catalog.md](./references/failure-catalog.md):

```bash
# A specific run:
./.github/skills/ghrunner-triage/scripts/triage.sh "$REPO" "$RUN_ID"
# The most recent failed run:
./.github/skills/ghrunner-triage/scripts/triage.sh --latest-failed "$REPO"
# A pasted error log (offline, no run needed):
printf '%s\n' "lsb_release: command not found" | ./.github/skills/ghrunner-triage/scripts/triage.sh --stdin
```

The script prints matched **IDs** (e.g. `IMG-LSB`). Look each up in
[references/failure-catalog.md](./references/failure-catalog.md) for the root
cause and handoff.

### Step 5 — Classify

Catalog categories: **IMAGE** (missing package/tool), **AUTH** (token/
credential/access), **WORKFLOW** (YAML/agent config), **CONFIG** (labels/
groups), **INFRA** (host/cluster/network).

### Step 6 — Recommend the fix (handoff)

State the matched ID(s), root cause, and the exact handoff. Do **not** execute
it — direct the user to the `ghrunner-ops` operation or doc below.

## Category → Handoff

| Category | Typical fix | Handoff |
|----------|-------------|---------|
| IMAGE | Bump runner image, then **recreate** the container (`:latest` snapshot rule) | `ghrunner-ops` `A4` + `A3` |
| AUTH (token TTL) | Redeploy with fresh token, or GH_PAT self-minting image | `ghrunner-ops` `A3` / `A6` |
| AUTH (private repo) | Move to ARC (GitHub App auth) | `docs/16-copilot-agent-arc-end-to-end.md` |
| WORKFLOW | Make runner ephemeral / disable agent firewall / pin versions | `ghrunner-ops` `A3`; `docs/15` |
| CONFIG | Align `runs-on` labels / runner group access | edit workflow / `docs/12` |
| INFRA | Start VM/AKS, free disk, fix DNS, resize | `ghrunner-ops` `A3`; `docs/12`, `docs/09` |

## Troubleshooting

| Symptom | Note |
|---------|------|
| Script prints "No known signature matched" | Collect logs manually ([diagnostics.md](./references/diagnostics.md)); consider adding a new catalog entry |
| `--latest-failed` finds nothing | No failed runs in recent history; pass an explicit `<repo> <run-id>` |
| ACI logs not appended | RG unreachable — pass `--subscription <id>` (never `az account set`) |
| Run stuck `queued`, no logs | Likely `CFG-LABEL` — compare `runs-on` to runner labels |

## References

- [references/failure-catalog.md](./references/failure-catalog.md) — signature → cause → fix, all platforms
- [references/diagnostics.md](./references/diagnostics.md) — evidence collection & per-platform commands
- [scripts/triage.sh](./scripts/triage.sh) — read-only triage (3 input modes)
- [`ghrunner-ops`](../ghrunner-ops/SKILL.md) — apply the recommended fixes
- [`ghrunner-provision`](../ghrunner-provision/SKILL.md) — provision & verify a runner (bring-up / prevention)
- [`gha-azure-oidc`](../gha-azure-oidc/SKILL.md) — passwordless GitHub→Azure auth for workflows
- [`runner-hardening-audit`](../runner-hardening-audit/SKILL.md) — audit posture (A6 unhealthy runners feed triage)
- `docs/12`, `docs/15`, `docs/09`, `docs/16`, `docs/runner-registry.md` — source troubleshooting knowledge
