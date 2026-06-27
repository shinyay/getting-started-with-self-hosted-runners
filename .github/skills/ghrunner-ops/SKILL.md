---
name: ghrunner-ops
license: MIT
description: >-
  Manage the ACI-hosted GitHub Actions self-hosted runner fleet defined in
  docs/runner-registry.md. Use when adding, redeploying, removing, or
  inventorying ghrunner-aci-NN containers in the ghrunner-rg resource group,
  rotating the GH_PAT, updating the runner image, or reconciling the registry
  ledger against live Azure/GitHub state. Presents an interactive operation
  menu, runs a read-only inventory script, and keeps docs/runner-registry.md in
  sync. Covers ACI runners plus the VM and AKS+ARC alternatives in this repo.
  Trigger phrases: self-hosted runner, ACI runner, ghrunner, runner registry,
  add runner, redeploy runner, runner inventory, reconcile runners, GH_PAT
  rotation, ghrunner-rg.
---

# ghrunner-ops — Self-Hosted Runner Fleet Operations

Menu-driven operations for the self-hosted GitHub Actions runner fleet in this
repository. The authoritative ledger is **`docs/runner-registry.md`** — this
skill orchestrates safe execution of the procedures documented there and keeps
the ledger in sync with reality.

## When to Use This Skill

- Add a runner for a new repository (`ghrunner-aci-NN`)
- Redeploy / recover a crashed runner, or remove / deregister one
- Inventory & reconcile the ledger against live Azure + GitHub state
- Update the runner container image (push a new `ghrunner:` tag to ACR)
- Rotate the long-lived `GH_PAT` (v0.6.0+ self-minting token)
- Stand up the VM or AKS+ARC alternatives, or maintain the docs

## Prerequisites

- `gh` CLI authenticated as the **fleet owner** (`shinyay`)
- `az` CLI authenticated and able to reach **`ghrunner-rg`**
- Tools: `az`, `gh`, `git`; `docker` for image work
- For `GH_PAT` operations: `export GH_PAT='github_pat_…'` in the environment

## Critical Guardrails — read before any action

> [!IMPORTANT]
> These rules prevent breaking the shared environment and the live fleet.

- **Never run `az account set`.** `~/.azure` is shared with other concurrent
  sessions; changing the default breaks them. Target a subscription with a
  per-command `--subscription <id>` instead.
- **Never stage, commit, delete, or modify the `resume` file** at the repo
  root. It is the user's Copilot CLI session-ID memo, unrelated to the project.
- **Registration tokens expire in ~1 hour.** Mint them immediately before
  `az container create`. For long-lived ephemeral runners, prefer the `GH_PAT`
  self-minting image (v0.6.0+).
- **ACI keeps the deploy-time image snapshot.** A container deployed with the
  mutable `:latest` tag does *not* auto-pull on restart. When reconciling, do
  **not** overwrite a recorded semantic version (e.g. `v0.6.1`) with the literal
  `latest` tag — the recorded deploy-time version is the better record.
- **High `restartCount` is normal for `EPHEMERAL=true` + `restart-policy
  Always`** runners (one job → exit → ACI restart). It is not a crash signal.
- **Mutating ops require explicit confirmation.** Show the exact command(s)
  first, then proceed only on user approval.

## The Operation Menu Flow

Follow these steps every time the skill is invoked.

### Step 1 — Preflight (always)

```bash
# Fleet owner must be the active gh account
gh auth status | grep -q 'Active account: true' && gh auth switch -u shinyay 2>/dev/null || true
gh api user --jq .login            # expect: shinyay

# Azure must reach the resource group (do NOT az account set)
az group show -n ghrunner-rg --query name -o tsv 2>&1
# If this fails, the wrong subscription is active. Find the right one and pass
# --subscription <id> on every az command (see Azure Coordinates below).
```

### Step 2 — Present the menu

Use the **`ask_user`** tool to render the operation menu as a single-select list
plus an optional free-text "supplement" field. Reproduce the menu in
[references/operations.md](./references/operations.md) (IDs `A1`–`A6`, `B1`,
`B2`, `C`, `D`). This *is* the interactive "function menu" the user expects.

### Step 3 — Gather details

From the supplement field or a follow-up `ask_user`, collect what the chosen
operation needs (target repository, runner number `NN`, `EPHEMERAL` yes/no,
image tag, etc.). See each operation's "Inputs" in
[references/operations.md](./references/operations.md).

### Step 4 — Confirm the plan

Print the exact command(s) that will run. For any **mutating** operation, stop
and get explicit approval before executing.

### Step 5 — Execute

Run the operation following its authoritative procedure:

- Read-only inventory (`A1`) → run [scripts/inventory.sh](./scripts/inventory.sh)
- All other operations → follow the linked section of `docs/runner-registry.md`
  (and [references/operations.md](./references/operations.md) for B/C/D).

### Step 6 — Update the ledger & offer to commit

- Update the **Current Runners** table (and **Image versions**, if relevant) in
  `docs/runner-registry.md` to match the new reality.
- Show `git --no-pager diff docs/runner-registry.md`.
- Offer to commit. **Stage only `docs/runner-registry.md`** (`git add
  docs/runner-registry.md`) so the untracked `resume` file is never included.
  Use a Conventional Commit message, e.g.
  `docs(runner-registry): <change>`.

## Operation Menu (summary)

| ID | Operation | Type | Procedure |
|----|-----------|------|-----------|
| `A1` | Inventory & reconcile ledger vs live state | read-only | [scripts/inventory.sh](./scripts/inventory.sh) |
| `A2` | Add a runner for a repository | mutating | registry §"How to Add a New Runner" |
| `A3` | Redeploy / recover a crashed runner | mutating | registry §"How to Redeploy a Crashed Runner" |
| `A4` | Update the runner image (ACR push) | mutating | [references/operations.md](./references/operations.md) |
| `A5` | Remove / deregister a runner | mutating | registry §"How to Add" (delete block) |
| `A6` | Rotate `GH_PAT` | mutating | registry §"GH_PAT — Setup and Rotation" |
| `B1` | VM runner (Bicep) | mutating | `bicep/vm-runner/`, `docs/07-vm-automation.md` |
| `B2` | AKS + ARC autoscaling | mutating | `k8s/arc/`, `docs/09-aks-arc-setup.md` |
| `C` | Image development (Dockerfile/entrypoint) | mutating | `containers/runner/` |
| `D` | Docs maintenance (registry / guides) | safe | `docs/` |

Full per-operation details: [references/operations.md](./references/operations.md).

## Azure Coordinates

| Resource | Value |
|----------|-------|
| Resource Group | `ghrunner-rg` (region `eastus`) |
| Container Registry | `shinyayacr202604.azurecr.io` |
| Runner Image | `shinyayacr202604.azurecr.io/ghrunner:latest` |
| Subscription (verify) | hosts `ghrunner-rg`; discover via `az group show` |

> Discover the subscription with
> `az group show -n ghrunner-rg --query id -o tsv` rather than assuming one.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `az group show` fails / RG not found | Wrong subscription active | Pass `--subscription <id>` per command; never `az account set` |
| Runner shows offline after ~1h | Registration token expired | Use the `GH_PAT` self-minting image (v0.6.0+) or recreate the container |
| `ask_user` selection but no inputs | Supplement left blank | Issue a follow-up `ask_user` for the operation's required inputs |
| Registry version ≠ live `:latest` tag | Expected for `:latest` deploys | Keep the recorded deploy-time version; do not write `latest` |
| Copilot coding agent jobs fail on dirty `_work` | Persistent (non-ephemeral) runner | Use `EPHEMERAL=true` + `--restart-policy Always` (see `docs/15`) |
| A runner job failed and the cause is unclear | Needs diagnosis first | Use the [`ghrunner-triage`](../ghrunner-triage/SKILL.md) skill to find the root cause, then return here |

## References

- [references/operations.md](./references/operations.md) — full menu + per-operation steps & inputs
- [scripts/inventory.sh](./scripts/inventory.sh) — read-only reconciliation (A1)
- [`ghrunner-triage`](../ghrunner-triage/SKILL.md) — diagnose **why** a runner job failed, then return here to apply the fix
- [`ghrunner-provision`](../ghrunner-provision/SKILL.md) — bring up & verify a new runner for a repo end-to-end
- [`runner-workflow-onboard`](../runner-workflow-onboard/SKILL.md) — migrate a repo's workflows to self-hosted after adding a runner (A2)
- `docs/runner-registry.md` — authoritative ledger and procedures
- `docs/08-aci-setup.md`, `docs/15-copilot-coding-agent.md` — ACI & Copilot agent specifics
