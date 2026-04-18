# AKS + Actions Runner Controller (ARC)

AKS combined with **Actions Runner Controller (ARC)** is the enterprise-grade solution for auto-scaling self-hosted runners on Kubernetes. ARC is GitHub's official Kubernetes operator that automatically provisions and manages runner pods in response to workflow job demand — including scaling from zero.

> [!NOTE]
> This is the most complex setup option. It requires Kubernetes experience. For simpler alternatives, see [VM Setup](06-vm-manual-setup.md) or [ACI Setup](08-aci-setup.md).

---

## Part 1: AKS Cluster Provisioning

### Create the Cluster

```bash
# Create resource group (if not already created)
az group create --name ghrunner-rg --location eastus

# Create AKS cluster
az aks create \
  --resource-group ghrunner-rg \
  --name ghrunner-aks \
  --node-count 2 \
  --node-vm-size Standard_D2s_v3 \
  --generate-ssh-keys \
  --enable-managed-identity \
  --network-plugin azure \
  --tags purpose=github-runner

# Get cluster credentials
az aks get-credentials \
  --resource-group ghrunner-rg \
  --name ghrunner-aks

# Verify connection
kubectl get nodes
```

### Node Pool Strategy

For production workloads, separate your AKS node pools by purpose:

| Pool | Purpose | Suggested VM Size | Notes |
|------|---------|-------------------|-------|
| **System pool** | ARC controller & cluster services | `Standard_D2s_v3` | Small, always-on |
| **User/Runner pool** | Runner pods | `Standard_D4s_v3` | Right-sized for your workloads |

Key considerations:

- **Taints & tolerations** — Taint the runner pool so only runner pods land there.
- **Cluster autoscaler** — Enable on the runner pool so nodes scale to zero when idle.
- **Labels** — Tag nodes with `purpose=github-runner` for easy identification.

```bash
# Optional: Add dedicated runner node pool
az aks nodepool add \
  --resource-group ghrunner-rg \
  --cluster-name ghrunner-aks \
  --name runnerpool \
  --node-count 1 \
  --node-vm-size Standard_D4s_v3 \
  --labels purpose=github-runner \
  --node-taints github-runner=true:NoSchedule \
  --max-count 5 \
  --min-count 0 \
  --enable-cluster-autoscaler
```

---

## Part 2: Create GitHub App for ARC Authentication

ARC authenticates with GitHub using a **GitHub App** (recommended over PATs for security and higher rate limits).

### Step 1 — Create the GitHub App

1. Navigate to: **Organization → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: `ARC Runner Controller` (must be globally unique)
   - **Homepage URL**: `https://github.com/YOUR-ORG`
   - **Webhook**: Uncheck **"Active"** (ARC does not use webhooks)

### Step 2 — Set Permissions

Under **"Repository permissions"**:

| Permission | Access |
|-----------|--------|
| Actions | Read-only |
| Administration | Read and write |
| Metadata | Read-only (auto-selected) |

Under **"Organization permissions"**:

| Permission | Access |
|-----------|--------|
| Self-hosted runners | Read and write |

### Step 3 — Finish Creation

1. **Where can this be installed?**: Select **"Only on this account"**
2. Click **Create GitHub App**
3. **Note the App ID** displayed at the top of the app's settings page

### Step 4 — Generate Private Key

1. Scroll down to the **"Private keys"** section
2. Click **"Generate a private key"**
3. Save the downloaded `.pem` file securely — you'll need it later

### Step 5 — Install the App

1. In the left sidebar, click **"Install App"**
2. Select your organization
3. Choose **"All repositories"** or select specific repositories → Click **"Install"**
4. **Note the Installation ID** from the URL: `https://github.com/organizations/YOUR-ORG/settings/installations/<INSTALLATION_ID>`

---

## Part 3: Deploy ARC Controller

The ARC controller watches for GitHub Actions jobs and manages runner pod lifecycle.

```bash
# Create namespaces
kubectl create namespace arc-systems
kubectl create namespace arc-runners

# Install ARC controller using Helm
helm install arc \
  --namespace arc-systems \
  --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# Verify controller is running
kubectl get pods -n arc-systems
# Expected: controller-manager pod in Running state

kubectl get all -n arc-systems
```

Wait for the controller to become ready before proceeding:

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=gha-runner-scale-set-controller \
  -n arc-systems \
  --timeout=120s
```

---

## Part 4: Deploy Runner Scale Set

### Create the GitHub App Secret

```bash
kubectl create secret generic github-app-secret \
  --namespace arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=<PATH_TO_PEM_FILE>
```

### Install the Runner Scale Set

You can install using inline `--set` flags:

```bash
helm install arc-runner-set \
  --namespace arc-runners \
  --create-namespace \
  --set githubConfigUrl="https://github.com/YOUR-ORG" \
  --set githubConfigSecret="github-app-secret" \
  --set runnerGroup="Default" \
  --set minRunners=0 \
  --set maxRunners=10 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

Or use the values file for a more maintainable setup:

```bash
helm install arc-runner-set \
  --namespace arc-runners \
  -f k8s/arc/values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### Understanding `values.yaml`

The [`k8s/arc/values.yaml`](../k8s/arc/values.yaml) file controls all aspects of the runner scale set:

| Section | Purpose |
|---------|---------|
| `githubConfigUrl` | Organization or repository URL that runners register to |
| `githubConfigSecret` | Credentials block — App ID, Installation ID, private key |
| `runnerGroup` | Runner group assignment (Enterprise Cloud feature) |
| `minRunners` / `maxRunners` | Scaling bounds — `0` allows scale-from-zero |
| `template.spec.containers` | Runner container image, commands, and resource limits |
| `containerMode` | Enable Docker-in-Docker if workflows need `docker` commands |

---

## Part 5: Auto-Scaling Configuration

### How ARC Auto-Scaling Works

ARC implements a **scale-from-zero** model:

1. **No idle runners** — When `minRunners: 0`, no runner pods exist until a job is queued.
2. **Job detection** — ARC watches the GitHub API for pending workflow jobs matching the runner scale set.
3. **Pod creation** — Runner pods are created on-demand when jobs are queued.
4. **Automatic cleanup** — Pods are destroyed after job completion (ephemeral runners).

Key settings:

- **`minRunners`** — Set to `1` or more for a "warm pool" that eliminates pod startup latency.
- **`maxRunners`** — Cap the maximum concurrent runners to control costs.

### Cluster Autoscaler Interaction

ARC and the AKS cluster autoscaler work together:

1. ARC requests more runner pods than current nodes can schedule.
2. The cluster autoscaler detects unschedulable pods and adds nodes.
3. When runner pods complete and are removed, nodes become idle.
4. The cluster autoscaler removes idle nodes after the cool-down period.

### Observe Scaling in Action

```bash
# Monitor auto-scaling in real-time
kubectl get pods -n arc-runners -w

# In another terminal, trigger multiple workflows
for i in {1..5}; do
  gh workflow run "Test Self-Hosted Runner"
  sleep 2
done
```

---

## Part 6: Network Policies

Runner pods should have restricted network access to follow the principle of least privilege. The [`k8s/arc/network-policy.yaml`](../k8s/arc/network-policy.yaml) file defines egress rules:

- **Deny all ingress** — Runner pods should not accept inbound connections.
- **Allow DNS** (port 53) — Required for name resolution.
- **Allow HTTPS** (port 443) — For GitHub API, Azure services, and package registries.
- **Allow HTTP** (port 80) — For package mirrors that don't support HTTPS.

Apply the policy:

```bash
kubectl apply -f k8s/arc/network-policy.yaml
```

> [!IMPORTANT]
> Network policies require a CNI plugin that supports them (e.g., Azure CNI with Network Policy, Calico). The `--network-plugin azure` flag used during cluster creation enables Azure CNI.

---

## Part 7: Using Custom Runner Images

If the default `actions-runner` image lacks tools your workflows need, build a custom image:

```bash
# Build custom image with additional tools
# (Use the Dockerfile from containers/runner/ as a base)
docker build -t ghrunneracr.azurecr.io/custom-runner:latest containers/runner/
az acr login --name ghrunneracr
docker push ghrunneracr.azurecr.io/custom-runner:latest

# Update Helm values to use custom image
helm upgrade arc-runner-set \
  --namespace arc-runners \
  --set template.spec.containers[0].image="ghrunneracr.azurecr.io/custom-runner:latest" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

> [!TIP]
> For ACR authentication, attach the ACR to your AKS cluster:
> `az aks update -n ghrunner-aks -g ghrunner-rg --attach-acr ghrunneracr`

---

## Part 8: Verification and Testing

### Check ARC Components

```bash
# Check controller status
kubectl get pods -n arc-systems

# Check runner scale set
kubectl get pods -n arc-runners

# Check ARC resources
kubectl get autoscalingrunnersets -n arc-runners
kubectl get ephemeralrunnersets -n arc-runners
kubectl get ephemeralrunners -n arc-runners
```

### Verify in GitHub

Navigate to **Organization → Settings → Actions → Runner groups**. You should see `arc-runner-set` listed as an available runner.

### Test with a Workflow

Create a workflow that targets your ARC runner:

```yaml
name: Test ARC Runner
on: workflow_dispatch
jobs:
  test:
    runs-on: arc-runner-set
    steps:
      - run: |
          echo "Running on ARC!"
          echo "Pod: $(hostname)"
          kubectl version --client 2>/dev/null || echo "kubectl not in runner image"
```

Trigger the workflow and watch pods appear:

```bash
kubectl get pods -n arc-runners -w
```

---

## Part 9: ARC Maintenance

### Upgrading ARC

```bash
# Upgrade controller
helm upgrade arc \
  --namespace arc-systems \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# Upgrade runner scale set
helm upgrade arc-runner-set \
  --namespace arc-runners \
  -f k8s/arc/values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### Monitoring

```bash
# Controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller -f

# Runner pod logs
kubectl logs -n arc-runners <pod-name>

# Events
kubectl get events -n arc-runners --sort-by='.lastTimestamp'
```

### Troubleshooting

| Issue | Cause | Resolution |
|-------|-------|------------|
| Controller `CrashLoopBackOff` | Invalid GitHub App credentials | Verify secret values match the GitHub App settings |
| Runners not scaling | Incorrect permissions | Ensure the GitHub App has `Self-hosted runners: Read and write` |
| Pods stuck in `Pending` | Insufficient node resources | Check `kubectl describe pod` for events; verify cluster autoscaler |
| Image pull errors | ACR not attached or image missing | Run `az aks update --attach-acr` and verify the image tag |
| `runs-on` label mismatch | Wrong runner scale set name | Ensure the workflow `runs-on` matches `runnerScaleSetName` in values |

---

## Part 10: Cleanup

```bash
# Remove runner scale set
helm uninstall arc-runner-set -n arc-runners

# Remove ARC controller
helm uninstall arc -n arc-systems

# Delete namespaces
kubectl delete namespace arc-runners
kubectl delete namespace arc-systems

# Delete AKS cluster
az aks delete --resource-group ghrunner-rg --name ghrunner-aks --yes --no-wait

# Or delete entire resource group
az group delete --name ghrunner-rg --yes --no-wait
```

---

← **Previous:** [ACI Setup](08-aci-setup.md) | **Next:** [OIDC & Workload Identity](10-oidc-workload-identity.md) →
