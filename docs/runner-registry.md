# Runner Registry — ACI Container ↔ Repository Mapping

This document tracks which ACI containers are running self-hosted runners and which repositories they serve.

## Current Runners

> [!NOTE]
> The **Labels** column shows the *custom* labels set via the `RUNNER_LABELS` env var. GitHub additionally auto-attaches `self-hosted`, `Linux`, and `X64`, so workflows should target `runs-on: [self-hosted, linux, azure, aci]`.
>
> The **Status** column annotates `(ephemeral)` when the runner is configured with `EPHEMERAL=true` and `--restart-policy Always`. Ephemeral runners exit after a single job (clean `_work` between jobs) and ACI restarts the container so the next runner registers automatically. This pattern is recommended for **GitHub Copilot coding agent** workloads, which fail on persistent runners due to leftover git state in `_work`. See [docs/15-copilot-coding-agent.md](15-copilot-coding-agent.md) for the full requirements and troubleshooting guide.

| Container | Repository | Labels (custom) | CPU | Memory | Status |
|-----------|-----------|-----------------|:---:|:------:|:------:|
| `ghrunner-aci-01` | [awesome-shinyay-knowledge-base-tech-articles](https://github.com/shinyay/awesome-shinyay-knowledge-base-tech-articles) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, v0.6.0) |
| `ghrunner-aci-02` | [awesome-shinyay-knowledge-base](https://github.com/shinyay/awesome-shinyay-knowledge-base) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-03` | [gh-changelog](https://github.com/shinyay/gh-changelog) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, v0.6.0) |
| `ghrunner-aci-04` | [gh-changelog-zenn](https://github.com/shinyay/gh-changelog-zenn) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, v0.6.1) |
| `ghrunner-aci-05` | [continuous-cloud-agent](https://github.com/shinyay/continuous-cloud-agent) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-06` | [dexter-for-japan](https://github.com/shinyay/dexter-for-japan) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-07` | [ghcp-6-layer-agentic-platform](https://github.com/shinyay/ghcp-6-layer-agentic-platform) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online (ephemeral, v0.6.1) |

## Azure Resources

| Resource | Name | Region |
|----------|------|--------|
| Resource Group | `ghrunner-rg` | `eastus` |
| Container Registry | `shinyayacr202604.azurecr.io` | `eastus` |
| Runner Image | `shinyayacr202604.azurecr.io/ghrunner:latest` | — |

### Image versions

| Tag | Changes |
|-----|---------|
| `v0.6.1` (current `latest`) | Bakes in Chromium runtime libraries (`libnss3`, `libgbm1`, `libasound2`, `fonts-noto-cjk`, etc.) so workflows that use Playwright/Puppeteer can run `playwright install chromium` (browser binary only) without `--with-deps` — the sudoless runner container cannot satisfy `apt-get install`. Triggered by `gh-changelog-zenn/daily-update.yml`. |
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
> Replace `YOUR-REPO` with the repository name and `NN` with the next available number (e.g., `08`, since `ghrunner-aci-07` is now serving `ghcp-6-layer-agentic-platform`).

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
> ⚠️ Caveat: the `RUNNER_TOKEN` baked into the container env is the original *registration* token, which expires in ~1 hour. After expiry, restarted containers will fail to re-register. For long-lived ephemeral runners, recreate the container periodically (or migrate to ARC on AKS, where pods are re-spawned by the controller with fresh tokens).

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

### Step 6: Update this document

Add the new runner to the **Current Runners** table above.

---

## GH_PAT (v0.6.0+) — Setup and Rotation

The v0.6.0+ runner image self-mints a registration token from a long-lived
**fine-grained Personal Access Token** (`GH_PAT`) on every container start.
This eliminates the 1-hour registration-token expiry that crashed
`EPHEMERAL=true` + `restart-policy=Always` runners.

### One-time PAT creation

1. https://github.com/settings/personal-access-tokens → **Generate new token**.
2. **Token name**: `ghrunner-self-mint`.
3. **Resource owner**: `shinyay`.
4. **Expiration**: 1 year (max).
5. **Repository access**: *Only select repositories* → pick all 8 runner-served
   repos (knowledge-base-tech-articles, awesome-shinyay-knowledge-base,
   gh-changelog, gh-changelog-zenn, continuous-cloud-agent, dexter-for-japan,
   ghcp-6-layer-agentic-platform-phase3-dry-run, ghcp-6-layer-agentic-platform).
6. **Repository permissions** → **Administration**: `Read and write`. Leave
   everything else at default (no access). This is the only permission needed
   for `POST /repos/:o/:r/actions/runners/registration-token`.
7. Generate, then copy the token. Store in your password manager.

### Local export (for the recreate script)

```bash
export GH_PAT='github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
```

### Rotate (annually, before expiry)

1. Generate a new PAT with the same scope (steps above).
2. `export GH_PAT='<new>'`
3. Re-run `recreate-runners.sh fragile` (or recreate runners individually).
   ACI re-creates each container with the new PAT in its secure env vars; the
   entrypoint will use it on every subsequent restart automatically.
4. Revoke the old PAT in GitHub UI.

> [!IMPORTANT]
> The PAT lives **inside the running container** as a secure env var (encrypted
> at rest in ACI; not visible in `az container show` output). It never touches
> `config.sh --token`, only the GitHub REST API.



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

Since runners use `restart-policy: Never`, a crashed container won't restart. To redeploy:

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
