---
name: arc-ops
license: MIT
description: >-
  Operate, scale, and verify an autoscaling self-hosted runner fleet on AKS with
  the Actions Runner Controller (ARC). Use when setting up, scaling, upgrading,
  or troubleshooting
  Kubernetes-based GitHub Actions runners: it provisions AKS, installs the ARC
  controller, deploys a gha-runner-scale-set for a repo, and verifies a real job
  runs green on an ARC runner pod. The Kubernetes counterpart to ghrunner-ops
  (ACI). Workflows target runs-on:<scale-set-name>. Covers PAT and GitHub App
  auth and common ARC failures (cluster Stopped, CrashLoopBackOff, Pending).
  Trigger phrases: ARC, Actions Runner Controller, AKS runners, runner scale set,
  gha-runner-scale-set, autoscaling runners, kubernetes self-hosted runner,
  arc-runners, listener pod.
---

# arc-ops — AKS + Actions Runner Controller operations

Bring up and operate an **autoscaling** self-hosted runner fleet on Kubernetes
with **ARC**. The K8s sibling of `ghrunner-ops` (which manages the ACI fleet).

## When to Use This Skill

- Stand up ARC on AKS for a repo (controller + runner scale set)
- Deploy / scale / upgrade a `gha-runner-scale-set`
- Verify an ARC scale set runs a job green on a runner pod
- Troubleshoot ARC (cluster Stopped → queued, CrashLoopBackOff, Pending pods)

## Key fact: scale-set name = `runs-on` label

A runner scale set registers under its **name**; workflows target
`runs-on: <scale-set-name>` (e.g. `arc-runner-set`), not the ACI fleet's
`[self-hosted, linux, azure, aci]`. With `minRunners: 0`, ARC spawns an ephemeral
runner pod per job and scales back to zero.

## Prerequisites

- `az` (AKS), `kubectl`, `helm`, `gh`; `git` + SSH push for the verify step
- Rights to create AKS + an AKS-admin kubeconfig
- A GitHub credential for ARC: a **token/PAT** with repo (or org) admin, or a
  **GitHub App** (App ID + installation ID + private key)

## Guardrails

- **Never run `az account set`** (`~/.azure` is shared); pass `--subscription`.
- **Never stage/commit/modify the untracked `resume` file.**
- **Secret handling**: the ARC token / App key is a secret — pass via env or
  `gh auth token`, let `kubectl create secret` store it, never echo it; `shred`
  a local App `.pem` after use.
- **Irreversible ops are Human-in-the-Loop**: repository deletion is print-only
  (`arc-down.sh --show-repo-delete`).
- **RG-scoped deletion**: `arc-down.sh --delete-cluster` only deletes the RG you
  name with `--rg` and **refuses** `ghrunner-rg` (the ACI fleet).

## Flow

### 1 — Bring up ARC (optionally provision AKS)
```bash
./.github/skills/arc-ops/scripts/arc-up.sh OWNER/REPO \
  --rg rg-arc-ops --aks aks-arc-ops --scale-set arc-runner-set \
  --provision --min 0 --max 2
```
Provisions AKS (with `--provision`), installs the ARC controller, creates the
auth secret (default `gh auth token`), deploys the scale set, and waits for the
listener to register. Details: [references/arc-operations.md](./references/arc-operations.md).

### 2 — Verify a job green on an ARC pod
```bash
./.github/skills/arc-ops/scripts/arc-verify.sh OWNER/REPO --scale-set arc-runner-set
```
Pushes a `runs-on: arc-runner-set` workflow over git+SSH, dispatches it, and
asserts `success` while reporting the ARC runner pod that ran it.

### 3 — Operate
Scale/observe, upgrade, and harden (NetworkPolicy) per
[references/arc-operations.md](./references/arc-operations.md). Diagnose failures
with [references/troubleshooting.md](./references/troubleshooting.md).

### 4 — Tear down
```bash
./.github/skills/arc-ops/scripts/arc-down.sh \
  --scale-set arc-runner-set --rg rg-arc-ops --delete-cluster \
  --repo OWNER/REPO --show-repo-delete --yes
```
Helm-uninstalls the scale set + controller and deletes the AKS RG; repo deletion
is Human-in-the-Loop.

## Auth options

| Method | Secret keys | When |
|--------|-------------|------|
| token / PAT | `github_token` | default; simplest (repo/org admin) |
| GitHub App | `github_app_id`, `github_app_installation_id`, `github_app_private_key` | orgs / private repos (docs/16) |

## Troubleshooting (top)

| Symptom | Fix |
|---------|-----|
| jobs `queued` + `kubectl` `no such host` | AKS Stopped → `az aks start` |
| runner pod `CrashLoopBackOff` | bad credentials → recreate the secret |
| pods `Pending` | no nodes → scale the node pool |
| no pod appears | `runs-on` ≠ scale-set name, or listener not registered |

Full catalog: [references/troubleshooting.md](./references/troubleshooting.md).

## References

- [references/arc-operations.md](./references/arc-operations.md) — operations catalog + auth + manual commands
- [references/troubleshooting.md](./references/troubleshooting.md) — ARC failure catalog
- [scripts/arc-up.sh](./scripts/arc-up.sh) · [scripts/arc-verify.sh](./scripts/arc-verify.sh) · [scripts/arc-down.sh](./scripts/arc-down.sh)
- [`ghrunner-ops`](../ghrunner-ops/SKILL.md) (ACI sibling) · [`ghrunner-triage`](../ghrunner-triage/SKILL.md) (`INF-AKS-STOPPED`, `AUTH-ARC-CREDS`) · [`runner-workflow-onboard`](../runner-workflow-onboard/SKILL.md)
- `docs/09-aks-arc-setup.md`, `docs/16-copilot-agent-arc-end-to-end.md`, `k8s/arc/*`
