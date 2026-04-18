# ACI Setup — Container-Based Runners

> [!WARNING]
> **ACI Limitations**: ACI runners are best for simple, short-lived, stateless jobs. They do **NOT** support Docker-in-Docker, service containers, or persistent caching. See [Decision Guide](02-decision-guide.md) for details.

This guide walks you through building a GitHub Actions self-hosted runner container image and deploying it to **Azure Container Instances (ACI)**. ACI is ideal for lightweight, ephemeral runners that spin up quickly without managing underlying infrastructure.

---

## Part 1: Build the Runner Container Image

### Dockerfile Walkthrough

The runner image is defined in [`containers/runner/Dockerfile`](../containers/runner/Dockerfile).

| Layer | Purpose |
|---|---|
| `ubuntu:22.04` | Base OS — LTS release with broad package support |
| System packages | `curl`, `jq`, `git`, `build-essential`, `python3`, `zip/unzip` for typical CI tasks; `docker.io` included for non-ACI platforms |
| Non-root user | `runner` (UID 1000) — the runner process never runs as root |
| Runner binary | GitHub Actions runner v2.321.0 downloaded and extracted |
| Dependencies | `./bin/installdependencies.sh` installs .NET and other runner prerequisites |
| Entrypoint | `entrypoint.sh` handles configuration, registration, and graceful shutdown |

### Entrypoint Script

The [`containers/runner/entrypoint.sh`](../containers/runner/entrypoint.sh) script is the heart of the container. It handles:

**Signal Handling for Graceful Shutdown**
The script traps `SIGTERM` and `SIGINT` so that when the container is stopped (e.g., `az container delete`), the runner deregisters itself from GitHub before exiting. This prevents ghost runners from appearing in your runner list.

**Ephemeral Mode**
When `EPHEMERAL=true` (the default), the runner accepts **one job** and then exits. This ensures a clean environment for every workflow run — no leftover files, no state leakage between jobs.

**Automatic Deregistration**
On shutdown, the `cleanup` function calls `./config.sh remove` to remove the runner registration from GitHub. If the token has expired, it logs a warning so you can clean up manually.

**Environment Variables**

| Variable | Required | Default | Description |
|---|---|---|---|
| `GITHUB_URL` | ✅ | — | Repository or org URL |
| `RUNNER_TOKEN` | ✅ | — | Registration token from GitHub |
| `RUNNER_NAME` | ❌ | `$(hostname)` | Display name for the runner |
| `RUNNER_LABELS` | ❌ | `azure,linux,x64,aci` | Comma-separated labels |
| `RUNNER_GROUP` | ❌ | `Default` | Runner group |
| `EPHEMERAL` | ❌ | `true` | Exit after one job |

### Build Locally

```bash
cd containers/runner
docker build -t ghrunner:latest .
```

### Test Locally

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/OWNER/REPO \
  -e RUNNER_TOKEN=<TOKEN> \
  -e RUNNER_NAME=local-test \
  ghrunner:latest
```

You should see the runner register, appear under **Settings → Actions → Runners** in your repository, and wait for a job. Press `Ctrl+C` to stop — the runner will deregister automatically.

---

## Part 2: Push to Azure Container Registry (ACR)

### Create an ACR Instance

```bash
# Create ACR
az acr create \
  --resource-group ghrunner-rg \
  --name ghrunneracr \
  --sku Basic \
  --admin-enabled true
```

### Login, Tag, and Push

```bash
# Login to ACR
az acr login --name ghrunneracr

# Tag and push
docker tag ghrunner:latest ghrunneracr.azurecr.io/ghrunner:latest
docker push ghrunneracr.azurecr.io/ghrunner:latest

# Verify
az acr repository list --name ghrunneracr --output table
```

You should see `ghrunner` in the repository list.

---

## Part 3: Deploy to ACI via Azure CLI

### Retrieve Credentials

```bash
# Get ACR credentials
ACR_USERNAME=$(az acr credential show -n ghrunneracr --query username -o tsv)
ACR_PASSWORD=$(az acr credential show -n ghrunneracr --query "passwords[0].value" -o tsv)

# Get runner registration token
RUNNER_TOKEN=$(gh api repos/OWNER/REPO/actions/runners/registration-token -X POST --jq '.token')
```

> [!NOTE]
> Registration tokens expire after **1 hour**. Generate the token immediately before deploying.

### Deploy the Container

```bash
az container create \
  --resource-group ghrunner-rg \
  --name ghrunner-aci-01 \
  --image ghrunneracr.azurecr.io/ghrunner:latest \
  --registry-login-server ghrunneracr.azurecr.io \
  --registry-username "$ACR_USERNAME" \
  --registry-password "$ACR_PASSWORD" \
  --cpu 2 \
  --memory 4 \
  --os-type Linux \
  --restart-policy OnFailure \
  --environment-variables \
    GITHUB_URL=https://github.com/OWNER/REPO \
    RUNNER_NAME=ghrunner-aci-01 \
    RUNNER_LABELS=azure,linux,x64,aci \
  --secure-environment-variables \
    RUNNER_TOKEN="$RUNNER_TOKEN"
```

> [!IMPORTANT]
> Use `--secure-environment-variables` for the runner token. This ensures the token is not visible in the Azure Portal or CLI output.

---

## Part 4: Ephemeral Runner Pattern

### How Ephemeral Mode Works

By default, the entrypoint configures the runner with `--ephemeral`. This means:

1. The runner registers with GitHub
2. It picks up **exactly one** job
3. After the job completes, the runner process exits
4. The container stops

### Restart Policies

| Policy | Behavior | Use Case |
|---|---|---|
| `Never` | Container stops after the runner exits | One-shot jobs, testing |
| `OnFailure` | Container restarts if the runner exits with an error | Continuous ephemeral runners (with caveats) |
| `Always` | Container always restarts | Not recommended for ephemeral runners |

### Caveats with `OnFailure`

When using `OnFailure` with ephemeral runners:

- The runner token is **baked into the environment** at deploy time
- Registration tokens expire after **1 hour**
- If the container restarts after the token expires, registration will fail

### Best Practice: Orchestrated Token Refresh

For production use, orchestrate runner deployment with **Azure Functions** or **Logic Apps**:

1. A timer-triggered function generates a fresh registration token
2. It deploys (or restarts) the ACI container with the new token
3. The ephemeral runner picks up one job and exits
4. The function detects the container has stopped and repeats

This pattern gives you fresh tokens and clean environments for every job.

---

## Part 5: Deploy with Bicep

For repeatable, version-controlled deployments, use the Bicep template at [`bicep/aci-runner/main.bicep`](../bicep/aci-runner/main.bicep).

### Template Overview

The Bicep template creates:

- A **Container Group** with a single container running the runner image
- **ACR authentication** using admin credentials from the referenced ACR resource
- **Environment variables** for runner configuration
- **Secure environment variables** for the runner token (never stored in plain text)

### Update Parameters

Edit [`bicep/aci-runner/main.parameters.json`](../bicep/aci-runner/main.parameters.json) with your values:

- `acrName` / `acrLoginServer` — your ACR instance
- `githubUrl` — your repository or organization URL
- `runnerToken` — a fresh registration token
- `runnerName` — a unique name for this runner

### Deploy

```bash
az deployment group create \
  --resource-group ghrunner-rg \
  --template-file bicep/aci-runner/main.bicep \
  --parameters bicep/aci-runner/main.parameters.json
```

You can also override individual parameters on the command line:

```bash
az deployment group create \
  --resource-group ghrunner-rg \
  --template-file bicep/aci-runner/main.bicep \
  --parameters bicep/aci-runner/main.parameters.json \
  --parameters runnerToken="$RUNNER_TOKEN" runnerName="ghrunner-aci-02"
```

---

## Part 6: Verification

### Check Container Status

```bash
az container show \
  --resource-group ghrunner-rg \
  --name ghrunner-aci-01 \
  --query "{Status:instanceView.state, IP:ipAddress.ip}" \
  --output table
```

### View Container Logs

```bash
az container logs \
  --resource-group ghrunner-rg \
  --name ghrunner-aci-01
```

You should see output like:

```
=============================================
  GitHub Actions Self-Hosted Runner
=============================================
  GitHub URL  : https://github.com/OWNER/REPO
  Runner Name : ghrunner-aci-01
  Labels      : azure,linux,x64,aci
  ...
>>> Configuring runner...
>>> Runner configured successfully.
>>> Starting runner...
```

### Verify in GitHub

Navigate to your repository (or organization):

**Settings → Actions → Runners**

You should see `ghrunner-aci-01` listed with the labels `azure,linux,x64,aci` and status **Idle** (waiting for jobs).

### Test with a Workflow

Create a workflow that targets your runner labels:

```yaml
# .github/workflows/test-aci-runner.yml
name: Test ACI Runner
on: workflow_dispatch
jobs:
  test:
    runs-on: [self-hosted, azure, aci]
    steps:
      - run: echo "Hello from ACI runner!"
      - run: uname -a
      - run: cat /etc/os-release
```

Trigger it manually and watch the logs in both GitHub and ACI.

---

## Part 7: Cleanup

### Delete the Container

```bash
az container delete --resource-group ghrunner-rg --name ghrunner-aci-01 --yes
```

### Delete ACR (if no longer needed)

```bash
az acr delete --name ghrunneracr --yes
```

### Remove Ghost Runners

If the container was deleted without graceful shutdown, the runner may still appear in GitHub. Remove it manually:

```bash
# List runners
gh api repos/OWNER/REPO/actions/runners --jq '.runners[] | "\(.id) \(.name) \(.status)"'

# Delete a specific runner by ID
gh api repos/OWNER/REPO/actions/runners/{RUNNER_ID} -X DELETE
```

---

← **Previous:** [VM Automation](07-vm-automation.md) | **Next:** [AKS + ARC Setup](09-aks-arc-setup.md) →
