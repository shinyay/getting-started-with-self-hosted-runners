# 17 — Agent Skills: Operate the Fleet Conversationally

> **Level:** 🟡 Intermediate → 🔴 Advanced
> **What you'll learn:** what the bundled **Agent Skills** are, how to invoke
> them, and a complete catalog of the **13 skills** that turn this repository
> into a conversational control plane for your self-hosted runner fleet.

This repository ships a suite of **GitHub Copilot Agent Skills** under
[`.github/skills/`](../.github/skills/). Where guides 01–16 teach you how to
build runners by hand, these skills let an agent (e.g. the **GitHub Copilot
CLI**) **do the work and verify it** — provisioning runners, triaging failures,
migrating workflows, auditing security, reporting cost, and mapping runner usage
across all your repositories — each proven end-to-end against real Azure +
GitHub resources.

---

## 🧩 What is an Agent Skill?

An **Agent Skill** is a folder containing a `SKILL.md` (instructions +
metadata), optional `scripts/` (automation), and `references/` (deeper docs).
Skills use **progressive disclosure** — the agent reads only the short
`description` first, and loads the full instructions and scripts **only when the
task matches**. This keeps the agent fast while giving it deep, on-demand
expertise.

```
.github/skills/<skill-name>/
├── SKILL.md          # required: frontmatter (name, description) + instructions
├── scripts/          # executable automation (run by the agent or by you)
└── references/       # detailed docs loaded on demand
```

See the [Agent Skills documentation](https://docs.github.com/copilot) for the
underlying mechanism.

---

## 🚀 How to invoke a skill

### Via the GitHub Copilot CLI (recommended)

The agent **auto-discovers** skills by matching your request against each
skill's `description` and **trigger phrases**. You don't name the skill — you
state the goal:

```text
> Provision a self-hosted runner for shinyay/my-repo and prove it works
   → invokes ghrunner-provision

> Which of my repos use self-hosted vs GitHub-hosted runners?
   → invokes runner-usage-map

> Audit the security posture of the runner fleet
   → invokes runner-hardening-audit
```

### Directly running a skill's scripts

Every skill's scripts are plain `bash`/`python3` and run standalone — handy for
CI or manual use. Each supports `--help`:

```bash
# Read-only fleet inventory
bash .github/skills/ghrunner-ops/scripts/inventory.sh --subscription <SUB>

# Security audit scorecard (read-only)
bash .github/skills/runner-hardening-audit/scripts/audit.sh -g ghrunner-rg --subscription <SUB>

# Cross-repo runner-usage census
bash .github/skills/runner-usage-map/scripts/usage-map.sh --limit 200
```

---

## 🏗️ Shared architecture

The analysis skills follow one battle-tested pattern (so they're trustworthy and
testable):

| Layer | Role | Property |
|-------|------|----------|
| **Pure engine** (`*_rules.py`, `classify.py`) | Apply logic to collected JSON → scorecard | No I/O → **offline unit-tested** |
| **Pure transform** (`normalize*.py`) | Raw `az`/`gh` JSON → normalized doc | No I/O → unit-tested |
| **Collectors** (`collect*.sh`) | Gather live facts | **Read-only** (`az … show/list`, `gh api` GETs) |
| **Orchestrator** (`*.sh`) | collect → engine → render + exit code | Live |
| **Mutating scripts** | Apply changes | **HITL**: dry-run by default, `--apply` to act |

Every skill is checked against the [Agent Skills
spec](https://docs.github.com/copilot) — valid frontmatter, no hardcoded
secrets, resolvable links — and the four analysis skills ship **~88 offline unit
tests** total (`23 + 22 + 18 + 25`) for their pure engines.

> [!IMPORTANT]
> **Safety model.** Census/analysis skills are **read-only**. Mutating or
> destructive actions are **Human-in-the-Loop**: scripts preview first and
> require `--apply`; repo/RG deletion is handed to you to run; `az` is always
> targeted with a trailing `--subscription <id>` (never `az account set`);
> secrets are never read by value or committed.

---

## 📚 Skill catalog (13 skills)

Grouped into five categories.

### 🛠️ Lifecycle — ACI fleet

| Skill | Use it to… | Key scripts |
|-------|-----------|-------------|
| [`ghrunner-ops`](../.github/skills/ghrunner-ops/SKILL.md) | Add / redeploy / remove / **inventory** ACI runners; rotate `GH_PAT`; keep `docs/runner-registry.md` in sync | `inventory.sh` |
| [`ghrunner-triage`](../.github/skills/ghrunner-triage/SKILL.md) | Diagnose **why a runner job failed** (matches logs to a failure catalog) and hand the fix to `ghrunner-ops` | `triage.sh` |
| [`ghrunner-provision`](../.github/skills/ghrunner-provision/SKILL.md) | **Bring up & verify** a runner for a repo end-to-end (build image → deploy ACI → smoke job green → teardown) | `provision-aci.sh`, `verify-runner.sh`, `teardown.sh` |

**Triggers:** *self-hosted runner, ACI runner, ghrunner, runner registry, add
runner, runner job failed, why did my workflow fail, provision runner, runner
smoke test.*
**Related guides:** [08 — ACI Setup](08-aci-setup.md),
[runner-registry](runner-registry.md), [12 — Monitoring](12-monitoring-maintenance.md).

### 🔐 Authentication

| Skill | Use it to… | Key scripts |
|-------|-----------|-------------|
| [`gha-azure-oidc`](../.github/skills/gha-azure-oidc/SKILL.md) | Set up & verify **passwordless GitHub→Azure** auth (OIDC / workload identity federation) — no stored client secret | `setup-oidc.sh`, `verify-oidc.sh`, `teardown-oidc.sh` |
| [`github-app-runner-auth`](../.github/skills/github-app-runner-auth/SKILL.md) | Authenticate runners/**ARC with a GitHub App** instead of a PAT (installation-id JWT → token chain → ARC k8s secret) | `app-installation-id.py`, `app-token.sh`, `make-arc-secret.sh` |

**Triggers:** *OIDC, workload identity federation, azure/login, passwordless
Azure, GitHub App auth, ARC GitHub App, installation id, app private key.*
**Related guides:** [05 — Auth & Tokens](05-github-auth-tokens.md),
[10 — OIDC & Workload Identity](10-oidc-workload-identity.md).

### ☁️ Platforms — VM & Kubernetes

| Skill | Use it to… | Key scripts |
|-------|-----------|-------------|
| [`arc-ops`](../.github/skills/arc-ops/SKILL.md) | Operate **AKS + Actions Runner Controller** autoscaling runners: provision AKS, install ARC, deploy a runner scale set, verify a job runs green on a pod, tear down | `arc-up.sh`, `arc-verify.sh`, `arc-down.sh` |
| [`vm-runner-ops`](../.github/skills/vm-runner-ops/SKILL.md) | Provision / verify / **decommission an Azure VM runner** via the repo's Bicep + cloud-init | `vm-up.sh`, `vm-verify.sh`, `vm-down.sh` |

**Triggers:** *ARC, Actions Runner Controller, AKS runners, runner scale set,
gha-runner-scale-set, VM runner, Azure VM self-hosted runner, cloud-init runner.*
**Related guides:** [07 — VM Automation](07-vm-automation.md),
[09 — AKS + ARC Setup](09-aks-arc-setup.md),
[16 — Copilot Agent Private-Repo E2E](16-copilot-agent-arc-end-to-end.md).

### 📦 Image & Workflows

| Skill | Use it to… | Key scripts |
|-------|-----------|-------------|
| [`ghrunner-image-release`](../.github/skills/ghrunner-image-release/SKILL.md) | **Build / tag / changelog / verify** the runner container image in ACR; recreate runners onto a new tag (the `:latest` snapshot rule) | `release-image.sh`, `verify-image.sh`, `recreate-on-image.sh`, `update_registry.py` |
| [`runner-workflow-onboard`](../.github/skills/runner-workflow-onboard/SKILL.md) | **Migrate a repo's workflows** from GitHub-hosted to self-hosted (rewrite `runs-on`, pin setup-action versions) and verify they still pass | `migrate-workflows.sh`, `transform_workflow.py`, `verify-migration.sh` |

**Triggers:** *release runner image, build ghrunner image, bump runner image,
migrate workflow to self-hosted, change runs-on, onboard repo to runners,
ubuntu-latest to self-hosted.*
**Related guides:** [13 — Sample Workflows](13-sample-workflows.md),
[runner-registry](runner-registry.md) (Image versions).

### 📊 Analysis — read-only audits & reports

| Skill | Use it to… | Key scripts |
|-------|-----------|-------------|
| [`runner-hardening-audit`](../.github/skills/runner-hardening-audit/SKILL.md) | **Scan security posture** of the fleet + a repo's Actions settings → PASS/WARN/FAIL scorecard (stale images, non-ephemeral, PAT-in-env, exposure, over-broad permissions, fork-PR gaps) | `audit.sh`, `audit_rules.py`, `collect.sh` |
| [`runner-fleet-health`](../.github/skills/runner-fleet-health/SKILL.md) | **Health snapshot** (availability, queue/wait, success rate, restarts) → HEALTHY/DEGRADED/UNHEALTHY; optional **opt-in Azure Monitor** up/down (cost-zeroing teardown) | `health.sh`, `health_rules.py`, `monitor-up.sh`, `monitor-down.sh` |
| [`runner-cost-optimizer`](../.github/skills/runner-cost-optimizer/SKILL.md) | **Cost report & right-sizing**: per-runner monthly cost + utilization → right-size / scale-to-zero / ARC-migration / reserved savings (live Azure Retail Prices optional) | `cost.sh`, `cost_rules.py`, `prices.py` |
| [`runner-usage-map`](../.github/skills/runner-usage-map/SKILL.md) | **Census across all your repos**: classify each as github-hosted / self-hosted / mixed / dynamic / none + Active status + flags; HITL toggle Active↔Non-active; delegate migration | `usage-map.sh`, `classify.py`, `runson.py`, `toggle-actions.sh` |

**Triggers:** *harden runners, runner security audit, runner health, fleet
health, monitor runners, runner cost, right-size runners, scale to zero, which
repos use self-hosted runners, runner usage, github-hosted vs self-hosted.*
**Related guides:** [11 — Security Hardening](11-security-hardening.md),
[12 — Monitoring](12-monitoring-maintenance.md),
[14 — Advanced Enterprise](14-advanced-enterprise.md).

---

## 🔍 "I want to…" → skill

| I want to… | Skill |
|------------|-------|
| Inventory / reconcile the ACI fleet | [`ghrunner-ops`](../.github/skills/ghrunner-ops/SKILL.md) |
| Find out why a runner job failed | [`ghrunner-triage`](../.github/skills/ghrunner-triage/SKILL.md) |
| Stand up a new runner for a repo and verify it | [`ghrunner-provision`](../.github/skills/ghrunner-provision/SKILL.md) |
| Log in to Azure from Actions without a secret | [`gha-azure-oidc`](../.github/skills/gha-azure-oidc/SKILL.md) |
| Authenticate ARC with a GitHub App | [`github-app-runner-auth`](../.github/skills/github-app-runner-auth/SKILL.md) |
| Run autoscaling runners on Kubernetes | [`arc-ops`](../.github/skills/arc-ops/SKILL.md) |
| Spin up / tear down a VM runner | [`vm-runner-ops`](../.github/skills/vm-runner-ops/SKILL.md) |
| Release a new runner image version | [`ghrunner-image-release`](../.github/skills/ghrunner-image-release/SKILL.md) |
| Move a repo's workflows to self-hosted | [`runner-workflow-onboard`](../.github/skills/runner-workflow-onboard/SKILL.md) |
| Check the fleet for security problems | [`runner-hardening-audit`](../.github/skills/runner-hardening-audit/SKILL.md) |
| Check whether the fleet is healthy / has capacity | [`runner-fleet-health`](../.github/skills/runner-fleet-health/SKILL.md) |
| See what the fleet costs and how to save | [`runner-cost-optimizer`](../.github/skills/runner-cost-optimizer/SKILL.md) |
| Map which repos use which runners (and disable dormant ones) | [`runner-usage-map`](../.github/skills/runner-usage-map/SKILL.md) |

---

## ✅ How the skills are verified

Each skill in this repo was proven **end-to-end against real Azure + GitHub**
(throwaway repos/resources spun up, a real job run green, then torn down), and
the analysis skills additionally ship **offline unit tests** for their pure
engines. The directory index lives at
[`.github/skills/README.md`](../.github/skills/README.md).

---

← **Previous:** [16 — Copilot Agent Private-Repo E2E](16-copilot-agent-arc-end-to-end.md) | [← Back to Tutorial Hub](README.md)
