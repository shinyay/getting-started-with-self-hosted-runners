# Runner Registry — ACI Container ↔ Repository Mapping

This document tracks which ACI containers are running self-hosted runners and which repositories they serve.

> [!TIP]
> **Operationalize this:** the [`ghrunner-ops`](../.github/skills/ghrunner-ops/SKILL.md) Agent Skill reconciles this ledger against live Azure + GitHub (`inventory.sh`) and runs the add/redeploy/remove procedures. See [17 — Agent Skills](17-agent-skills.md).

## Current Runners

> [!NOTE]
> The **Labels** column shows the *custom* labels set via the `RUNNER_LABELS` env var. GitHub additionally auto-attaches `self-hosted`, `Linux`, and `X64`, so workflows should target `runs-on: [self-hosted, linux, azure, aci]`.
>
> The **Status** column annotates `(ephemeral)` when the runner is configured with `EPHEMERAL=true` and `--restart-policy Always`. Ephemeral runners exit after a single job (clean `_work` between jobs) and ACI restarts the container so the next runner registers automatically. This pattern is recommended for **GitHub Copilot coding agent** workloads, which fail on persistent runners due to leftover git state in `_work`. See [docs/15-copilot-coding-agent.md](15-copilot-coding-agent.md) for the full requirements and troubleshooting guide.
>
> `ghrunner-aci-14` is the only runner still authenticated with a one-shot `RUNNER_TOKEN` instead of `GH_PAT`. That is safe *because* it is persistent: the token is consumed once at first registration, after which the runner holds its own long-lived credentials, so the 1-hour TTL never applies. The trade-off is `restart-policy=Never` — if the container dies it does not come back and jobs queue silently. Re-provision it with `GH_PAT` + `EPHEMERAL=true` to bring it in line with the rest of the fleet.

| Container | Repository | Labels (custom) | CPU | Memory | Status |
|-----------|-----------|-----------------|:---:|:------:|:------:|
| `ghrunner-aci-01` | [awesome-shinyay-knowledge-base-tech-articles](https://github.com/shinyay/awesome-shinyay-knowledge-base-tech-articles) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-02` | [awesome-shinyay-knowledge-base](https://github.com/shinyay/awesome-shinyay-knowledge-base) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-03` | [gh-changelog](https://github.com/shinyay/gh-changelog) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-04` | [gh-changelog-zenn](https://github.com/shinyay/gh-changelog-zenn) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-05` | [continuous-cloud-agent](https://github.com/shinyay/continuous-cloud-agent) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-06` | [dexter-for-japan](https://github.com/shinyay/dexter-for-japan) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-07` | [ghcp-6-layer-agentic-platform](https://github.com/shinyay/ghcp-6-layer-agentic-platform) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-08` | [getting-started-with-token-optimization](https://github.com/shinyay/getting-started-with-token-optimization) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-09` | [gh-internal-notes](https://github.com/shinyay/gh-internal-notes) (private) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (GH_PAT, v0.6.5) |
| `ghrunner-aci-10` | [polyclaw-jp](https://github.com/shinyay/polyclaw-jp) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-11` | [tokopt](https://github.com/shinyay/tokopt) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (GH_PAT, v0.6.5) |
| `ghrunner-aci-12` | [knowlege-base-template](https://github.com/shinyay/knowlege-base-template) (private) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-13` | [knowlege-base-spring-boot](https://github.com/shinyay/knowlege-base-spring-boot) (private) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |
| `ghrunner-aci-14` | [getting-started-with-copilot-app](https://github.com/shinyay/getting-started-with-copilot-app) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (RUNNER_TOKEN, restart=Never, v0.6.5) |
| `ghrunner-aci-15` | [aks-latest-features-lab](https://github.com/shinyay/aks-latest-features-lab) (private) | `azure,linux,x64,aci` | 1 | 2 GB | ✅ Online (ephemeral, GH_PAT, restart=Always, v0.6.5) |

## Azure Resources

| Resource | Name | Region |
|----------|------|--------|
| Resource Group | `ghrunner-rg` | `eastus` |
| Container Registry | `shinyayacr202604.azurecr.io` | `eastus` |
| Runner Image | `shinyayacr202604.azurecr.io/ghrunner:latest` | — |

### Image versions

| Tag | Changes |
|-----|---------|
| `v0.6.5` (current `latest`) | Straight rebuild of the `v0.6.4` Dockerfile — no recipe change, just a refreshed base image and apt packages. Digest `sha256:2d0ccfd…`, built 2026-08-06; the whole fleet was recreated on it. |
| `v0.6.4` | Bumps `actions/runner` to **2.335.1** (from 2.333.1). GitHub began mandating 2.335.1, and the baked 2.333.1 could not persist its in-container auto-update across `EPHEMERAL=true` + `restart-policy=Always` restarts — the runner busy-looped on "Runner update in progress" and never completed queued jobs (observed: `ghrunner-aci-01` at 190 restarts, CI starved). Re-baking at 2.335.1 removes the forced update. |
| `v0.6.3` | Adds the **Azure CLI** (`az`) from the official `packages.microsoft.com` apt repo so `azure/login@v2` and any `az` workflow step work on the runner. Without it those steps failed with `Unable to locate executable file: az`. Verified live: `azure/login@v2` + `az account show` green on an OIDC-configured runner. |
| `v0.6.2-lsb-fix` | Adds `lsb-release` and `gnupg` so `actions/setup-python@v5` can install its Python toolchain on the sudoless runner container (the action's installer probes `lsb_release -a` and the deadsnakes PPA via `gpg`). Without these packages, Python setup failed with `lsb_release: command not found` and `gpg: command not found`. Commit `d833bd0`. |
| `v0.6.1` | Bakes in Chromium runtime libraries (`libnss3`, `libgbm1`, `libasound2`, `fonts-noto-cjk`, etc.) so workflows that use Playwright/Puppeteer can run `playwright install chromium` (browser binary only) without `--with-deps` — the sudoless runner container cannot satisfy `apt-get install`. Triggered by `gh-changelog-zenn/daily-update.yml`. |
| `v0.6.0` | Entrypoint now self-mints a fresh registration token on every container start using a long-lived `GH_PAT` (fine-grained PAT with `Administration: read & write`). Eliminates the 1-hour registration-token TTL bomb that crashed `EPHEMERAL=true` + `restart-policy=Always` runners after ~1 hour. Backwards-compatible with `RUNNER_TOKEN` for legacy v0.5.x containers. Also fixes graceful deregister (now mints a real `remove-token`). |
| `v0.5.0` | Installs GitHub CLI (`gh`) so workflows that auto-create/merge PRs (e.g. knowledge-base ingestion, evolution, synthesis) succeed on self-hosted runners. Previously these steps failed with `gh: command not found`. |
| `v0.4.0` | Installs `libyaml-0-2` so `ruby/setup-ruby@v1` prebuilt binaries can load (PR #3). |
| `v0.3.0` | Bumps `actions/runner` to `2.333.1` for `node24` support, required by `actions/checkout@v5` and other v5 actions (PR #2). |
| `v0.2.0` | Pre-creates `/opt/hostedtoolcache` owned by the `runner` user so `ruby/setup-ruby@v1` (which hard-codes this path and ignores `RUNNER_TOOL_CACHE`) can install toolchains (PR #1). |
| `v0.1.0` | Initial image. |

> [!NOTE]
> Existing ACI containers keep their original image snapshot and are not affected when a new `:latest` is pushed. To apply a new image, recreate the container (see **How to Redeploy a Crashed Runner**).

---

## How to Add a New Runner for a Repository

> [!IMPORTANT]
> **Fleet standard for new runners:** `GH_PAT` (self-minting) +
> `EPHEMERAL=true` + `--restart-policy Always`. Steps 1 and 3 below show the
> **legacy** one-shot `RUNNER_TOKEN` path (`--restart-policy Never`,
> `EPHEMERAL=false`), kept for reference. For a new runner:
>
> 1. Ask the operator which token to use as `GH_PAT` — see
>    [Token source](#token-source). Do not assume a stored PAT exists.
> 2. Skip Step 1: the entrypoint mints a fresh registration token on every
>    container start.
> 3. In Step 3, set `--restart-policy Always` and `EPHEMERAL=true`, and pass
>    `GH_PAT="$GH_PAT"` instead of `RUNNER_TOKEN="$RUNNER_TOKEN"` under
>    `--secure-environment-variables`.
>
> **Size:** the fleet default is 2 vCPU / 4 GB (`--cpu 2 --memory 4`); 1 vCPU /
> 2 GB (`--cpu 1 --memory 2`) is enough for light CI.

### Step 1: Get a registration token

```bash
RUNNER_TOKEN=$(gh api repos/shinyay/YOUR-REPO/actions/runners/registration-token \
  -X POST --jq '.token')
```

### Step 2: Get ACR credentials

```bash
ACR_USERNAME=$(az acr credential show -n shinyayacr202604 \
  --resource-group ghrunner-rg --query username -o tsv)
ACR_PASSWORD=$(az acr credential show -n shinyayacr202604 \
  --resource-group ghrunner-rg --query "passwords[0].value" -o tsv)
```

### Step 3: Deploy the ACI container

```bash
az container create \
  --resource-group ghrunner-rg \
  --name ghrunner-aci-NN \
  --image shinyayacr202604.azurecr.io/ghrunner:latest \
  --registry-login-server shinyayacr202604.azurecr.io \
  --registry-username "$ACR_USERNAME" \
  --registry-password "$ACR_PASSWORD" \
  --cpu 2 --memory 4 --os-type Linux \
  --restart-policy Never \
  --environment-variables \
    GITHUB_URL=https://github.com/shinyay/YOUR-REPO \
    RUNNER_NAME=ghrunner-aci-NN \
    RUNNER_LABELS=azure,linux,x64,aci \
    EPHEMERAL=false \
  --secure-environment-variables \
    RUNNER_TOKEN="$RUNNER_TOKEN"
```

> [!IMPORTANT]
> Replace `YOUR-REPO` with the repository name and `NN` with the next available number (e.g., `16`, since `ghrunner-aci-15` is now serving `aks-latest-features-lab`).

> [!TIP]
> **Ephemeral mode (recommended for GitHub Copilot coding agent and any workload sensitive to dirty `_work` state):**
> Set `EPHEMERAL=true` and `--restart-policy Always`. The runner exits after one job (clean `_work` between jobs) and ACI restarts the container so a fresh runner re-registers.
>
> ```bash
> # ... same as above, but change these two lines:
>   --restart-policy Always \
>     EPHEMERAL=true \
> ```
>
> ⚠️ Caveat: the `RUNNER_TOKEN` baked into the container env is the original *registration* token, which expires in ~1 hour. After expiry, restarted containers will fail to re-register. For long-lived ephemeral runners, use `GH_PAT` instead (the fleet standard at the top of this section), or migrate to ARC on AKS, where pods are re-spawned by the controller with fresh tokens.

### Step 4: Verify

```bash
# Check container logs
az container logs --resource-group ghrunner-rg --name ghrunner-aci-NN

# Verify runner in GitHub
gh api repos/shinyay/YOUR-REPO/actions/runners \
  --jq '.runners[] | {name, status}'
```

### Step 5: Update your workflows

In the target repository, change `runs-on` in your workflow files:

```yaml
# Before
runs-on: ubuntu-latest

# After
runs-on: [self-hosted, linux, azure, aci]
```

> [!NOTE]
> If your workflow uses `actions/setup-node` without `node-version`, add it:
> ```yaml
> - uses: actions/setup-node@v6
>   with:
>     node-version: '20'
> ```

Also apply the
[manual fixes](../.github/skills/runner-workflow-onboard/references/migration-rules.md#manual-fixes-not-auto-applied)
that the onboarding transform does not make — e.g. `actions/setup-python` jobs
need `env: AGENT_TOOLSDIRECTORY: /opt/hostedtoolcache`, and `docker build` /
`docker run` steps can't run on ACI.

### Step 6: Update this document

Add the new runner to the **Current Runners** table above.

---

## GH_PAT (v0.6.0+) — Setup and Rotation

The v0.6.0+ runner image self-mints a registration token on every container
start from a long-lived GitHub token passed in `GH_PAT` (see
[Token source](#token-source)). This eliminates the 1-hour registration-token
expiry that crashed `EPHEMERAL=true` + `restart-policy=Always` runners.

### Token source

`GH_PAT` only needs to be able to call
`POST /repos/{owner}/{repo}/actions/runners/registration-token` for the
runner's repository. Two sources work:

| Option | How to get it | Privilege |
|--------|---------------|-----------|
| **(a)** Fine-grained PAT | [One-time PAT creation](#one-time-pat-creation-option-a) below | Least privilege: only `Administration: Read and write` on the repositories you grant |
| **(b)** The operator's GitHub CLI token | `gh auth token` | Broader: the scopes of the operator's `gh` login (e.g. `repo`, which covers every repository the operator can access) |

With either option, **any job that runs on the runner can read the token**, so
(b) puts a much broader credential within reach of every workflow on that
runner. Use (b) only with the operator's explicit approval.

> [!IMPORTANT]
> **For agents:** do not assume a stored PAT exists, and do not ask the
> operator to paste a token they do not have. Ask which source to use — (a) or
> (b) — before provisioning. Never read `GH_PAT` back out of a running
> container (e.g. `az container exec ... printenv`).

### One-time PAT creation (option a)

1. https://github.com/settings/personal-access-tokens → **Generate new token**.
2. **Token name**: `ghrunner-self-mint`.
3. **Resource owner**: `shinyay`.
4. **Expiration**: 1 year (max).
5. **Repository access**: *All repositories* (covers any current or future
   runner-served repo without re-issuing the PAT each time a new runner is
   added). If you prefer a tighter blast radius, use *Only select repositories*,
   add every repository in **Current Runners**, and add each new runner's
   repository to the PAT *before* deploying that runner (otherwise the
   entrypoint cannot mint a registration token and the container exits).
6. **Repository permissions** → **Administration**: `Read and write`. Leave
   everything else at default (no access). This is the only permission needed
   for `POST /repos/:o/:r/actions/runners/registration-token`.
7. Generate, then copy the token. Store in your password manager.

### Local export

```bash
# (a) fine-grained PAT
export GH_PAT='github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
# (b) the operator's GitHub CLI token — only with the operator's explicit approval
export GH_PAT="$(gh auth token)"
```

### Rotate (annually, before expiry)

1. Get a new token from the chosen source (see [Token source](#token-source)).
2. `export GH_PAT='<new>'`
3. Recreate each `GH_PAT`-backed runner (see **How to Redeploy a Crashed
   Runner**) so the new token is baked into its secure env vars; the
   entrypoint uses it on every subsequent restart automatically.
4. Revoke the old token once no runner uses it.

> [!IMPORTANT]
> `GH_PAT` lives **inside the running container** as a secure env var:
> encrypted at rest in ACI and not visible in `az container show` output, but
> readable by every job that runs on the runner. It never touches
> `config.sh --token`, only the GitHub REST API.

---

## How to Remove a Runner

```bash
# 1. Delete the ACI container
az container delete --resource-group ghrunner-rg --name ghrunner-aci-NN --yes

# 2. Remove stale runner from GitHub (if it shows offline)
RUNNER_ID=$(gh api repos/shinyay/YOUR-REPO/actions/runners \
  --jq '.runners[] | select(.name == "ghrunner-aci-NN") | .id')
gh api repos/shinyay/YOUR-REPO/actions/runners/$RUNNER_ID -X DELETE
```

---

## How to Redeploy a Crashed Runner

A container with `--restart-policy Never` (the legacy `RUNNER_TOKEN` setup)
won't restart after a crash; ACI restarts `Always` containers by itself. To
recreate a runner, keep the settings recorded in **Current Runners**
(ephemeral, restart policy, CPU/memory). For a `GH_PAT` runner, skip step 2 and
pass `GH_PAT` (see [Token source](#token-source)) as in the fleet standard at
the top of **How to Add a New Runner**. To redeploy:

```bash
# 1. Delete the old container
az container delete --resource-group ghrunner-rg --name ghrunner-aci-NN --yes

# 2. Get a fresh registration token
RUNNER_TOKEN=$(gh api repos/shinyay/YOUR-REPO/actions/runners/registration-token \
  -X POST --jq '.token')

# 3. Redeploy (same command as Step 3 above)
```

> [!WARNING]
> Registration tokens expire in **1 hour**. Generate the token immediately before deploying.

---

## Quick Reference Commands

```bash
# List all ACI runners
az container list --resource-group ghrunner-rg \
  --query "[].{Name:name, Status:instanceView.state}" -o table

# Check a specific runner's logs
az container logs --resource-group ghrunner-rg --name ghrunner-aci-NN

# Check runner status in GitHub
gh api repos/shinyay/YOUR-REPO/actions/runners \
  --jq '.runners[] | {name, status, busy}'

# Delete ALL runners (nuclear option)
az group delete --name ghrunner-rg --yes --no-wait
```
