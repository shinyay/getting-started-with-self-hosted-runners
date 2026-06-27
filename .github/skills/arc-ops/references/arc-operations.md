# ARC Operations — AKS + Actions Runner Controller

Operating an autoscaling self-hosted runner fleet on Kubernetes with **ARC**
(Actions Runner Controller). The scripted path is `arc-up.sh` / `arc-verify.sh`
/ `arc-down.sh`; this catalog explains each operation and the manual equivalents.
Grounded in `docs/09-aks-arc-setup.md`, `docs/16-copilot-agent-arc-end-to-end.md`,
and `k8s/arc/*`.

## Key concept: the scale-set name IS the `runs-on` label

A gha-runner-scale-set registers a runner scale set whose **name** is used as the
workflow label. Workflows target `runs-on: <scale-set-name>` (e.g.
`runs-on: arc-smoke-set`) — **not** `[self-hosted, linux, azure, aci]` like the
ACI fleet. With `minRunners: 0`, no runner pods exist until a job arrives; ARC
scales up an ephemeral pod per job and scales back down.

## Charts & namespaces

| Component | Helm chart (OCI) | Namespace |
|-----------|------------------|-----------|
| Controller | `ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller` | `arc-systems` |
| Runner scale set | `ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set` | `arc-runners` |

## Authentication options (the secret)

The scale set reads GitHub credentials from a Kubernetes secret. Three options:

| Method | Secret keys | Notes |
|--------|-------------|-------|
| **PAT / token** | `github_token` | Simplest to automate; needs repo (or org) admin. `arc-up.sh` uses this by default (`gh auth token` or `--github-token`). |
| **GitHub App** | `github_app_id`, `github_app_installation_id`, `github_app_private_key` | Canonical for orgs/private repos (docs/16). The App is created in the web UI (Human-in-the-Loop); derive the installation ID via the JWT trick in docs/16 §3. |

> [!IMPORTANT]
> Treat the token / private key as a secret: pass it via env or `gh auth token`,
> let `kubectl create secret` store it, and never echo it. For a GitHub App key,
> `shred -u` the local `.pem` after creating the secret (docs/16 §4).

## Operations

### Provision AKS
```bash
az group create -n "$RG" -l "$LOCATION"
az aks create -g "$RG" -n "$AKS" -l "$LOCATION" \
  --node-count 1 --node-vm-size Standard_D2s_v3 --generate-ssh-keys --tier free
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
```
~6 min for a 1-node `--tier free` cluster (docs/16 worked example).

### Install the controller
```bash
helm install arc --namespace arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

### Create the auth secret
```bash
kubectl create namespace arc-runners
kubectl -n arc-runners create secret generic arc-github-secret \
  --from-literal=github_token="$(gh auth token)"
```

### Deploy a runner scale set
```bash
helm install arc-runner-set --namespace arc-runners \
  --set githubConfigUrl="https://github.com/OWNER/REPO" \
  --set githubConfigSecret=arc-github-secret \
  --set runnerScaleSetName=arc-runner-set \
  --set minRunners=0 --set maxRunners=4 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```
A `*-listener` pod in `arc-systems` long-polls GitHub for jobs.

### Scale / observe
```bash
kubectl get autoscalingrunnersets,ephemeralrunnersets,ephemeralrunners -n arc-runners
kubectl get pods -n arc-runners        # runner pods appear per job, vanish after
```

### Upgrade ARC
Upgrade the scale set first, then the controller, to the same chart version:
```bash
helm upgrade arc-runner-set -n arc-runners <scale-set-chart> --reuse-values
helm upgrade arc -n arc-systems <controller-chart>
```

### Network policy (optional hardening)
Apply `k8s/arc/network-policy.yaml` (deny-all ingress; egress 443/80/53) to
restrict runner pod traffic; required when the agent firewall is off (docs/16 §6).

### Teardown
```bash
helm uninstall arc-runner-set -n arc-runners
helm uninstall arc -n arc-systems
az group delete -n "$RG" --yes --no-wait     # deletes the whole AKS cluster
```

## Custom runner images

ARC runner pods use `ghcr.io/actions/actions-runner:latest` by default (set via
the chart `template.spec.containers[].image`). This is **GitHub's** runner image,
not this repo's `ghrunner` ACI image — the ACI image work (v0.6.x) does not apply
to ARC pods. See `docs/09` Part 7 for using a custom image.
