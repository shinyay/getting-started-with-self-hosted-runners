# Agent Skills — Self-Hosted Runner Fleet

This directory contains **13 GitHub Copilot Agent Skills** that operate the
self-hosted runner fleet described in this repository. An agent (e.g. the GitHub
Copilot CLI) discovers a skill by matching your request against its `description`
and trigger phrases, then runs its scripts and verifies the result.

📖 **Full guide:** [docs/17-agent-skills.md](../../docs/17-agent-skills.md) —
what Agent Skills are, how to invoke them, the shared architecture, and the
safety model.

> [!NOTE]
> **Safety:** analysis/census skills are **read-only**. Mutating or destructive
> actions are **Human-in-the-Loop** (dry-run by default, `--apply` to act; repo/
> resource-group deletion is handed to you). Secrets are never read by value or
> committed.

## Catalog

### 🛠️ Lifecycle — ACI fleet
| Skill | Purpose |
|-------|---------|
| [`ghrunner-ops`](ghrunner-ops/SKILL.md) | Add / redeploy / remove / inventory ACI runners; rotate `GH_PAT`; keep the registry in sync |
| [`ghrunner-triage`](ghrunner-triage/SKILL.md) | Diagnose why a runner job failed and recommend a fix |
| [`ghrunner-provision`](ghrunner-provision/SKILL.md) | Bring up & verify a runner for a repo end-to-end |

### 🔐 Authentication
| Skill | Purpose |
|-------|---------|
| [`gha-azure-oidc`](gha-azure-oidc/SKILL.md) | Passwordless GitHub→Azure auth via OIDC / workload identity federation |
| [`github-app-runner-auth`](github-app-runner-auth/SKILL.md) | Authenticate runners / ARC with a GitHub App instead of a PAT |

### ☁️ Platforms — VM & Kubernetes
| Skill | Purpose |
|-------|---------|
| [`arc-ops`](arc-ops/SKILL.md) | Operate AKS + Actions Runner Controller autoscaling runners |
| [`vm-runner-ops`](vm-runner-ops/SKILL.md) | Provision / verify / decommission an Azure VM runner |

### 📦 Image & Workflows
| Skill | Purpose |
|-------|---------|
| [`ghrunner-image-release`](ghrunner-image-release/SKILL.md) | Build / tag / changelog / verify the runner container image |
| [`runner-workflow-onboard`](runner-workflow-onboard/SKILL.md) | Migrate a repo's workflows from GitHub-hosted to self-hosted |

### 📊 Analysis — read-only audits & reports
| Skill | Purpose |
|-------|---------|
| [`runner-hardening-audit`](runner-hardening-audit/SKILL.md) | Security-posture scan of the fleet + a repo's Actions settings |
| [`runner-fleet-health`](runner-fleet-health/SKILL.md) | Health snapshot + opt-in Azure Monitor (cost-zeroing teardown) |
| [`runner-cost-optimizer`](runner-cost-optimizer/SKILL.md) | Cost report + right-sizing / scale-to-zero recommendations |
| [`runner-usage-map`](runner-usage-map/SKILL.md) | Census of which repos use which runners + Active toggle |

## Running a skill's scripts directly

Every skill's scripts run standalone and support `--help`:

```bash
bash ghrunner-ops/scripts/inventory.sh --subscription <SUB>
bash runner-hardening-audit/scripts/audit.sh -g ghrunner-rg --subscription <SUB>
bash runner-usage-map/scripts/usage-map.sh --limit 200
```
