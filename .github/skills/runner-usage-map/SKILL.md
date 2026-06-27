---
name: runner-usage-map
license: MIT
description: >-
  Inventory and map which of your GitHub repositories use GitHub-hosted vs
  self-hosted runners across your whole account. Use when you need to check or
  audit runner usage at scale: list every repo classified as github-hosted /
  self-hosted / mixed / dynamic / none, see whether each is Active or dormant,
  spot self-hosted repos whose runner is offline, find GitHub-hosted repos to
  migrate, and export the result as Markdown, CSV or JSON. Read-only census; an
  optional Human-in-the-Loop toggle switches a repo's Actions (or a single
  workflow) between Active and Non-active (dry-run by default). Migration to
  self-hosted is delegated to runner-workflow-onboard. Pairs with ghrunner-ops,
  ghrunner-provision, runner-fleet-health, runner-cost-optimizer. Trigger
  phrases: which repos use self-hosted runners, runner usage, repo runner
  inventory, github-hosted vs self-hosted, active workflows, disable actions,
  runner census, audit runners across repos.
---

# runner-usage-map — Cross-Repo Runner Usage Census

The top-level **"which of my repos use what runner, and is it Active?"** map.
It scans your repositories, classifies each repo's runner strategy, reports
Active status and flags (e.g. **self-hosted but offline**), and can toggle
Actions on/off or hand off a migration.

Classification & flags: **[references/classification.md](./references/classification.md)**.
Census / toggle / migration: **[references/workflows.md](./references/workflows.md)**.

## When to Use This Skill

- "Which repos use self-hosted vs GitHub-hosted runners?" — at account scale
- Find **self-hosted repos whose runner is offline** (broken / wasteful)
- Find **GitHub-hosted repos to migrate** to self-hosted
- See which repos are **Active vs dormant**; export CSV for review
- Switch a repo (or a workflow) **Active ↔ Non-active**

## What It Classifies

| Per repo | Values |
|----------|--------|
| **Strategy** | github_hosted · self_hosted · mixed · dynamic · none |
| **Active** | recent run within `--active-days` OR an online runner (Actions enabled) |
| **Flags** | SELF_HOSTED_BUT_OFFLINE · HOSTED_CANDIDATE · ACTIONS_DISABLED · DORMANT · DYNAMIC_REVIEW · NO_WORKFLOWS |

## Prerequisites

- `gh` CLI authenticated as the account owner (**`shinyay`**)
- `jq`, `python3` (standard library), `base64`
- No Azure / `az` needed — this is pure GitHub

## Guardrails

> [!IMPORTANT]
> The census is read-only. The toggle is HITL and dry-run by default.

- **`usage-map.sh` never mutates** anything.
- **`toggle-actions.sh` is PREVIEW by default** — `--apply` performs the change,
  and it **refuses any repo in the protect list** (default: this repo).
- Migration is **delegated** to `runner-workflow-onboard` (not reimplemented).
- **Do not commit reports** (`.gitignore` excludes `reports/`, `*.usage.*`).
  Never commit `resume` or `*.pem`.
- Large accounts: use `--limit`, `--repo`, or `--no-runson` to bound API calls.

## The Flow

### Step 1 — Census (read-only)

```bash
S=.github/skills/runner-usage-map/scripts
bash "$S/usage-map.sh" --limit 200                          # whole account (Markdown)
bash "$S/usage-map.sh" --limit 200 --format csv --out fleet.usage.csv
bash "$S/usage-map.sh" --limit 200 --strict                 # gate on offline self-hosted
bash "$S/usage-map.sh" --limit 200 --suggest-migrations     # hosted -> self-hosted hints
```

### Step 2 — Present & route

Lead with the summary (strategy counts, active/dormant, **self-hosted-offline**,
hosted-candidates). Route flags to the related skill (see
[classification.md](./references/classification.md)).

### Step 3 — Act (HITL)

```bash
# Toggle Active <-> Non-active (preview first, then --apply):
bash "$S/toggle-actions.sh" --repo owner/repo --disable-actions          # preview
bash "$S/toggle-actions.sh" --repo owner/repo --disable-actions --apply  # do it

# Migrate a hosted candidate (delegated):
bash .github/skills/runner-workflow-onboard/scripts/migrate-workflows.sh owner/repo --apply
```

## Scripts

| Script | Role | I/O |
|--------|------|-----|
| `scripts/runson.py` | Pure: classify & extract `runs-on` | pure |
| `scripts/normalize_usage.py` | Pure transform: raw gh JSON → doc | pure |
| `scripts/classify.py` | Pure engine: strategy + Active + flags; md/csv/json | pure |
| `scripts/collect-usage.sh` | Live read-only collectors (`gh`) | live |
| `scripts/usage-map.sh` | Census orchestrator (+ `--suggest-migrations`) | live |
| `scripts/toggle-actions.sh` | HITL toggle (dry-run default, `--apply`) | live, mutating |
| `scripts/test_classify.py` | Offline unit tests | pure |

## Verify

```bash
S=.github/skills/runner-usage-map/scripts
python3 "$S/test_classify.py"                              # offline unit tests
python3 "$S/classify.py" "$S/fixtures/sample-usage.json"   # demo classification
```

## Related Skills

- **runner-workflow-onboard** — performs hosted→self-hosted migration (delegate)
- **ghrunner-provision** / **ghrunner-ops** — supply / manage a runner
- **runner-fleet-health** — health of the self-hosted repos found here
- **runner-cost-optimizer** — cost of those self-hosted runners
- Ledger: **`docs/runner-registry.md`**
