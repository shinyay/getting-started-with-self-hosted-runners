---
name: runner-workflow-onboard
license: MIT
description: >-
  Migrate a repository's GitHub Actions workflows from GitHub-hosted to
  self-hosted runners and verify they still pass. Use when onboarding a repo to
  the self-hosted fleet: it rewrites runs-on (ubuntu-latest, pinned ubuntu-22.04,
  quoted, single-item list) to your self-hosted labels, pins missing
  setup-node/setup-python versions, previews a diff, applies over git+SSH, and
  proves a migrated workflow runs green on a real runner. Warns on matrix runs-on.
  Trigger phrases: migrate workflow to self-hosted, change runs-on, onboard repo
  to runners, ubuntu-latest to self-hosted, convert workflow runner, self-hosted
  CI migration, runs-on self-hosted.
---

# runner-workflow-onboard — Migrate workflows to self-hosted

Convert a repo's workflows from GitHub-hosted to self-hosted runners and
**verify** they still pass. The companion to `ghrunner-provision`: provision a
runner, then migrate the workflows to target it.

## When to Use This Skill

- A repo just got a self-hosted runner and its workflows still say `ubuntu-latest`
- Rewrite `runs-on` across all workflows to the fleet's labels
- Apply known compatibility fixes (setup-node/setup-python version pinning)
- Confirm a migrated workflow runs green on the runner

## Prerequisites

- `git` + **SSH push** to the target repo (no `workflow` token scope needed)
- `python3` (for the transformer), `gh` (for verification)
- A registered runner for the live verify step (use **ghrunner-provision**,
  `ghrunner` v0.6.3+ image)

## Guardrails

- **Preview by default.** The migrate script only writes/pushes with `--apply`.
- **Workflows only.** Only files under `.github/workflows/` are edited.
- **git+SSH** for pushing migrated workflows; **irreversible ops (repo deletion)
  are Human-in-the-Loop.**
- Never `az account set`; never touch the untracked `resume` file.
- **Warn, don't guess**, on matrix/expression `runs-on` — map those by hand.

## Flow

### 1 — Preview the migration
```bash
./.github/skills/runner-workflow-onboard/scripts/migrate-workflows.sh OWNER/REPO
```
Resolves the repo (`owner/repo` clones over SSH; a local clone path is edited in
place), transforms every `.github/workflows/*.{yml,yaml}` with
[transform_workflow.py](./scripts/transform_workflow.py), and prints a **diff**
plus a change log and any matrix warnings. Nothing is pushed.

### 2 — Apply
```bash
./.github/skills/runner-workflow-onboard/scripts/migrate-workflows.sh OWNER/REPO --apply
```
Commits the migrated workflows and pushes over git+SSH.

### 3 — Provision a runner
Use the **[ghrunner-provision](../ghrunner-provision/SKILL.md)** skill to bring
up a runner (v0.6.3+ image) for the repo, if one isn't already online.

### 4 — Verify green
```bash
./.github/skills/runner-workflow-onboard/scripts/verify-migration.sh \
  OWNER/REPO --workflow ci.yml --runner <runner-name>
```
Dispatches the workflow, asserts `success`, and that the job's labels include
`self-hosted`. Details: [references/verification.md](./references/verification.md).

### 5 — On failure
Hand off to **[ghrunner-triage](../ghrunner-triage/SKILL.md)** (e.g. a missing
tool → image bump via `ghrunner-ops` A4+A3; label mismatch → re-check `runs-on`).

## What gets changed

| Source `runs-on` | Result |
|------------------|--------|
| `ubuntu-latest` / pinned / quoted / `[ubuntu-latest]` | `[self-hosted, linux, azure, aci]` |
| `${{ matrix.os }}` | **warn, unchanged** |

Plus: `actions/setup-node` → `node-version: '20'`, `actions/setup-python` →
`python-version: '3.12'` when missing. Full rules:
[references/migration-rules.md](./references/migration-rules.md).

## Options

| Option | Meaning |
|--------|---------|
| `--apply` | commit + push (default is preview/diff only) |
| `--labels L` | target runs-on labels (default `self-hosted,linux,azure,aci`) |
| `--node-version V` / `--python-version V` | versions to pin when missing |
| `--branch B` | branch to push to (default: repo default) |

## References

- [references/migration-rules.md](./references/migration-rules.md) — mappings, compat catalog, matrix/copilot notes
- [references/verification.md](./references/verification.md) — verify a migrated workflow green
- [scripts/transform_workflow.py](./scripts/transform_workflow.py) · [scripts/migrate-workflows.sh](./scripts/migrate-workflows.sh) · [scripts/verify-migration.sh](./scripts/verify-migration.sh)
- [`ghrunner-provision`](../ghrunner-provision/SKILL.md) · [`ghrunner-ops`](../ghrunner-ops/SKILL.md) · [`ghrunner-triage`](../ghrunner-triage/SKILL.md) · [`gha-azure-oidc`](../gha-azure-oidc/SKILL.md)
- `docs/13-sample-workflows.md`, `docs/runner-registry.md` (Step 5), `docs/15-copilot-coding-agent.md`
