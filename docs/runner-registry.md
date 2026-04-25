# Runner Registry — ACI Container ↔ Repository Mapping

This document tracks which ACI containers are running self-hosted runners and which repositories they serve.

## Current Runners

| Container | Repository | Labels | CPU | Memory | Status |
|-----------|-----------|--------|:---:|:------:|:------:|
| `ghrunner-aci-01` | [awesome-shinyay-knowledge-base-tech-articles](https://github.com/shinyay/awesome-shinyay-knowledge-base-tech-articles) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-02` | [awesome-shinyay-knowledge-base](https://github.com/shinyay/awesome-shinyay-knowledge-base) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-03` | [gh-changelog](https://github.com/shinyay/gh-changelog) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-04` | [gh-changelog-zenn](https://github.com/shinyay/gh-changelog-zenn) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-05` | [continuous-cloud-agent](https://github.com/shinyay/continuous-cloud-agent) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-06` | [dexter-for-japan](https://github.com/shinyay/dexter-for-japan) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |
| `ghrunner-aci-07` | [ghcp-6-layer-agentic-platform-phase3-dry-run](https://github.com/shinyay/ghcp-6-layer-agentic-platform-phase3-dry-run) | `azure,linux,x64,aci` | 2 | 4 GB | ✅ Online |

## Azure Resources

| Resource | Name | Region |
|----------|------|--------|
| Resource Group | `ghrunner-rg` | `eastus` |
| Container Registry | `shinyayacr202604.azurecr.io` | `eastus` |
| Runner Image | `shinyayacr202604.azurecr.io/ghrunner:latest` | — |

### Image versions

| Tag | Changes |
|-----|---------|
| `v0.2.0` (current `latest`) | Pre-creates `/opt/hostedtoolcache` owned by the `runner` user so `ruby/setup-ruby@v1` (which hard-codes this path and ignores `RUNNER_TOOL_CACHE`) can install toolchains. |
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
> Replace `YOUR-REPO` with the repository name and `NN` with the next available number (e.g., `07`).

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
