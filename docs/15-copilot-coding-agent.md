# Tips for Running GitHub Copilot Coding Agent on Self-Hosted Runners

> **Field notes from running the Copilot Coding Agent against self-hosted runners on Azure** — what works, what breaks, and the four things you must get right.

GitHub Copilot Coding Agent can target self-hosted runners as of [October 2025](https://github.blog/changelog/2025-10-28-copilot-coding-agent-now-supports-self-hosted-runners/). The official documentation covers the *happy path* (ARC on Kubernetes) but several real-world failure modes — especially on **vanilla self-hosted runners** like the Azure Container Instances (ACI) fleet maintained in this repository — are only described in community discussions and blog posts.

This page collects those gotchas in one place.

---

## ✅ TL;DR — The Four Requirements

| # | Requirement | Why | Severity |
|---|-------------|-----|:--------:|
| 1 | A `.github/workflows/copilot-setup-steps.yml` workflow with a single job named `copilot-setup-steps` and the right `runs-on` | Copilot resolves the runner from this exact filename / job name | 🔴 Hard requirement |
| 2 | The repository-level **agent firewall must be OFF** for self-hosted runners | The agent firewall is unsupported outside GitHub-hosted infra and silently blocks the job | 🔴 Hard requirement |
| 3 | The runner must be **ephemeral** (`--ephemeral` / `EPHEMERAL=true`) | Copilot re-clones the repo every run; a dirty `_work/` from a previous job causes `fatal: refusing to merge unrelated histories` | 🔴 Hard requirement (vanilla self-hosted) |
| 4 | For **private repositories**, use **ARC** (GitHub App auth) — vanilla self-hosted hits `Repository not found` because the default `GITHUB_TOKEN` provided to the agent does not have access | Vanilla self-hosted is effectively limited to public repos today | 🟠 Practical limitation |

> [!IMPORTANT]
> Items **#1 and #2** are explicitly documented by GitHub. Items **#3 and #4** are community-validated knowledge as of this writing — they are not (or only superficially) covered in official docs.

---

## 1. `copilot-setup-steps.yml` — Job Name and `runs-on`

Copilot Coding Agent looks for a file at exactly `.github/workflows/copilot-setup-steps.yml`. Inside it, a single job whose name is exactly `copilot-setup-steps` must exist. The agent uses this job's `runs-on` to choose the runner.

**Minimal example for an ACI runner registered with labels `azure,linux,x64,aci`:**

```yaml
name: "Copilot Setup Steps"

on:
  workflow_dispatch:
  push:
    paths:
      - .github/workflows/copilot-setup-steps.yml
  pull_request:
    paths:
      - .github/workflows/copilot-setup-steps.yml

jobs:
  copilot-setup-steps:
    runs-on: [self-hosted, linux, azure, aci]
    permissions:
      contents: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@v5
      - name: Setup Node
        uses: actions/setup-node@v6
        with:
          node-version: '20'
      - name: Install dependencies
        run: npm ci
```

**Common mistakes:**

| Symptom | Cause | Fix |
|---|---|---|
| Agent shows "queued" forever | `runs-on` doesn't match any registered runner labels | Match the runner's actual labels (incl. `self-hosted`, `Linux`, `X64` which GitHub auto-attaches) |
| Agent ignores the file | Filename or job name typo | Must be exactly `copilot-setup-steps.yml` and `copilot-setup-steps` |
| Job fails on `actions/checkout@v5` with `node24 not found` | Runner version is too old | Bump runner image to `actions/runner ≥ 2.327` (this repo's image is at `2.333.1` since v0.3.0) |

**Reference:** [Customizing the development environment for Copilot coding agent](https://docs.github.com/copilot/customizing-copilot/customizing-the-development-environment-for-copilot-coding-agent).

---

## 2. Disable the Repository-Level Agent Firewall

The Copilot Coding Agent ships with its own egress firewall that allow-lists a curated set of hosts. **This firewall does not work on self-hosted runners** and must be turned off, or every agent task will fail with network errors before it does anything useful.

**Disable via UI:**

1. Repository → **Settings** → **Code & automation** → **Copilot** → **Coding agent**
2. Locate the **Agent firewall** toggle
3. Switch it **OFF**

**Disable via API:** see the official short-link [`gh.io/cca-self-hosted-disable-firewall`](https://gh.io/cca-self-hosted-disable-firewall) for the current REST endpoint and required scopes.

> [!WARNING]
> Disabling the agent firewall does **not** remove network protection — it just delegates egress control to your own infrastructure. On Azure ACI / VM / AKS, restrict egress at the NSG / Container Apps networking / NetworkPolicy layer. See [11 — Security Hardening](11-security-hardening.md) and [04 — Networking & Connectivity](04-networking-connectivity.md).

---

## 3. The Runner Must Be Ephemeral

### Symptom

```text
Previous HEAD position was fee3028 Initial commit
HEAD is now at <new-sha>
fatal: refusing to merge unrelated histories
```

The Copilot agent's `cloneRepo` step bails out part-way through and the job fails before any agent reasoning happens.

### Root cause

Vanilla self-hosted runners (whether on a VM or in a long-running container) keep their `_work/` directory **between jobs** by default. The Copilot agent assumes a clean working directory on each run and performs operations (additional `git pull` / re-clone) that are incompatible with the prior repo's git history left over in `_work/`. GitHub-hosted runners and ARC-managed pods don't have this problem because each job gets a fresh environment.

### Fix

Run the runner in **ephemeral mode**, where the runner process exits after a single job and the container/VM is recycled.

For ACI, this repository's runner image already supports it via the `EPHEMERAL` env var. Combine with `--restart-policy Always` so ACI re-creates the container after the runner exits:

```bash
az container create \
  --resource-group ghrunner-rg \
  --name ghrunner-aci-NN \
  --image shinyayacr202604.azurecr.io/ghrunner:latest \
  --restart-policy Always \
  --environment-variables \
    GITHUB_URL=https://github.com/OWNER/REPO \
    RUNNER_NAME=ghrunner-aci-NN \
    RUNNER_LABELS=azure,linux,x64,aci \
    EPHEMERAL=true \
  --secure-environment-variables \
    RUNNER_TOKEN="$RUNNER_TOKEN" \
  # ... (image / ACR creds as in runner-registry.md Step 3)
```

See [`docs/runner-registry.md` → Step 3 → "Ephemeral mode" TIP](runner-registry.md#how-to-add-a-new-runner-for-a-repository) for the complete command.

> [!CAUTION]
> The `RUNNER_TOKEN` baked into the container env is a **registration token that expires in ~1 hour**. After expiry, an ACI-restarted container can no longer re-register and will crash-loop. For long-lived ephemeral runners, either:
> - Periodically recreate the container with a fresh token, **or**
> - Migrate to **ARC on AKS** (see [09 — AKS + ARC Setup](09-aks-arc-setup.md)), where the controller mints fresh JIT tokens for every new pod.

---

## 4. Private Repos: ARC vs Vanilla Self-Hosted

### Symptom

On a vanilla self-hosted runner pointed at a **private** repository, the Copilot agent fails very early with:

```text
remote: Repository not found.
fatal: repository 'https://github.com/OWNER/PRIVATE-REPO.git/' not found
```

…even though the runner is correctly registered to that repo.

### Root cause

The Copilot Coding Agent uses the `GITHUB_TOKEN` it receives at job start to authenticate its own git operations against GitHub. On a vanilla self-hosted runner this token does **not** carry the scopes needed to read the private repo's contents in the way the agent expects (notably, fetching the merge base / re-cloning).

ARC (Actions Runner Controller) sidesteps this because it authenticates via a **GitHub App** installed on the org/repo, and the resulting token has the right scopes for the agent's git plumbing. Public repos work on vanilla self-hosted because the clone doesn't require authentication.

### Comparison

| Aspect | Vanilla self-hosted (VM / ACI) | ARC on AKS |
|---|:---:|:---:|
| Public repos | ✅ Works | ✅ Works |
| Private repos with Copilot Coding Agent | ❌ `Repository not found` | ✅ Works |
| Per-job ephemerality | Manual (`EPHEMERAL=true` + restart policy) | ✅ Native (new pod per job) |
| Auth model | Registration token (1h TTL) → runner principal | GitHub App → JIT runner token |
| Officially-supported configuration for Copilot Coding Agent | ⚠️ Works but with caveats | ✅ Recommended |
| This repo's worked example | `ghrunner-aci-07` | [09 — AKS + ARC Setup](09-aks-arc-setup.md) |

**Recommendation:** if you need Copilot Coding Agent on **private** repos, deploy ARC on AKS. Reserve vanilla self-hosted for public repos or non-Copilot CI workloads.

---

## 🧪 Worked Example — `ghrunner-aci-07`

This repository operates `ghrunner-aci-07` as a Copilot Coding Agent runner for the public repo [`shinyay/ghcp-6-layer-agentic-platform-phase3-dry-run`](https://github.com/shinyay/ghcp-6-layer-agentic-platform-phase3-dry-run). Configuration:

| Setting | Value | Reason |
|---|---|---|
| Image | `shinyayacr202604.azurecr.io/ghrunner:latest` (v0.4.0) | Includes runner 2.333.1 (node24-ready) and `libyaml-0-2` |
| `EPHEMERAL` env | `true` | Requirement #3 |
| `--restart-policy` | `Always` | So ACI re-creates the container after each ephemeral job |
| Repo agent firewall | OFF | Requirement #2 |
| `copilot-setup-steps.yml` | Present, `runs-on: [self-hosted, linux, azure, aci]` | Requirement #1 |
| Repo visibility | Private (with caveat — see [#4](#4-private-repos-arc-vs-vanilla-self-hosted)) | Demonstrates the limitation |

See [`docs/runner-registry.md`](runner-registry.md) for the full fleet inventory and operations runbook.

---

## ❓ Troubleshooting FAQ

<details>
<summary><strong>"refusing to merge unrelated histories"</strong></summary>

You're on a non-ephemeral runner. Apply requirement #3.
</details>

<details>
<summary><strong>"Repository not found" on a private repo</strong></summary>

Vanilla self-hosted's `GITHUB_TOKEN` lacks the scopes the agent expects. Move that repo to ARC, or make the repo public if appropriate. See requirement #4.
</details>

<details>
<summary><strong>The agent run sits in "queued" forever</strong></summary>

The `runs-on` labels on `copilot-setup-steps.yml` don't match any registered runner. List your runners with:

```bash
gh api repos/OWNER/REPO/actions/runners --jq '.runners[] | {name, labels: [.labels[].name]}'
```

…and align `runs-on` to the labels you see.
</details>

<details>
<summary><strong>The agent fails with network errors before the first step</strong></summary>

The agent firewall is still on. Apply requirement #2.
</details>

<details>
<summary><strong>The agent's <code>actions/checkout@v5</code> step fails with <code>node24</code> errors</strong></summary>

Your runner binary is older than 2.327. Rebuild your runner image with a newer `RUNNER_VERSION` (this repo pins 2.333.1). See the image history in [`docs/runner-registry.md`](runner-registry.md#image-versions).
</details>

<details>
<summary><strong>An ephemeral ACI runner crash-loops after about an hour</strong></summary>

The registration token in the container env expired. Recreate the container with a fresh token (see [`docs/runner-registry.md` → How to Redeploy a Crashed Runner](runner-registry.md#how-to-redeploy-a-crashed-runner)) or migrate to ARC.
</details>

---

## 📚 References

**Official:**
- [Copilot coding agent now supports self-hosted runners — GitHub Changelog (2025-10-28)](https://github.blog/changelog/2025-10-28-copilot-coding-agent-now-supports-self-hosted-runners/)
- [Customizing the development environment for Copilot coding agent](https://docs.github.com/copilot/customizing-copilot/customizing-the-development-environment-for-copilot-coding-agent)
- [Disable the agent firewall (`gh.io/cca-self-hosted-disable-firewall`)](https://gh.io/cca-self-hosted-disable-firewall)
- [Actions Runner Controller — Quickstart](https://docs.github.com/actions/tutorials/use-actions-runner-controller/quickstart)

**Community (source of truth for #3 and #4 today):**
- [Discussion #169220 — Self Hosted Copilot Agent](https://github.com/orgs/community/discussions/169220)
- [Discussion #177903 — Private Infra Ready: Copilot Coding Agent + Your Self-hosted](https://github.com/orgs/community/discussions/177903)
- [Zenn (kesin11) — Running GitHub Copilot Coding Agent on self-hosted runners](https://zenn.dev/kesin11/articles/20251029_github_coding_agent_self_hosted_runner?locale=en)

---

← **Previous:** [Advanced Enterprise](14-advanced-enterprise.md) | [← Back to Tutorial Hub](README.md)
