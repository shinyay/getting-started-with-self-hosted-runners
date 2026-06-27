#!/usr/bin/env bash
#
# arc-up.sh — bring up Actions Runner Controller (ARC) on AKS for a repo.
#
# Optionally provisions an AKS cluster, installs the ARC controller, creates the
# GitHub auth secret, and deploys an autoscaling runner scale set. Workflows then
# target `runs-on: <scale-set-name>`.
#
# Usage:
#   arc-up.sh <owner/repo> [options]
# Options:
#   --rg RG                 AKS resource group (default: rg-arc-ops)
#   --aks NAME              AKS cluster name (default: aks-arc-ops)
#   --location LOC          Azure region (default: eastus)
#   --provision             create the AKS cluster (default: assume it exists)
#   --node-size SIZE        VM size (default: Standard_D2s_v3)
#   --scale-set NAME        runner scale set name = runs-on label (default: arc-runner-set)
#   --min N                 min runners (default: 0)
#   --max N                 max runners (default: 2)
#   --ns-controller NS      controller namespace (default: arc-systems)
#   --ns-runners NS         runners namespace (default: arc-runners)
#   --secret-name NAME      k8s secret name (default: arc-github-secret)
#   --github-token GH_AUTH    ARC auth token (default: `gh auth token`)
#   --auth token|app        auth method (default: token)
#   --github-app-id ID      (--auth app) GitHub App id
#   --installation-id N     (--auth app) App installation id
#   --private-key-file PATH (--auth app) App private key (.pem)
#   --subscription ID       az subscription (never az account set)
#   --help
# The token/App key is written only into the cluster secret; it is never echoed.

set -uo pipefail

RG="rg-arc-ops"; AKS="aks-arc-ops"; LOCATION="eastus"; PROVISION="false"
NODE_SIZE="Standard_D2s_v3"; SCALE_SET="arc-runner-set"; MIN=0; MAX=2
NS_CTL="arc-systems"; NS_RUN="arc-runners"; SECRET_NAME="arc-github-secret"
GH_AUTH=""; SUBSCRIPTION=""; REPO=""
AUTH="token"; APP_ID=""; APP_INSTALL_ID=""; APP_KEY_FILE=""
CTRL_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
SS_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rg) RG="${2:?}"; shift 2;;
    --aks) AKS="${2:?}"; shift 2;;
    --location) LOCATION="${2:?}"; shift 2;;
    --provision) PROVISION="true"; shift;;
    --node-size) NODE_SIZE="${2:?}"; shift 2;;
    --scale-set) SCALE_SET="${2:?}"; shift 2;;
    --min) MIN="${2:?}"; shift 2;;
    --max) MAX="${2:?}"; shift 2;;
    --ns-controller) NS_CTL="${2:?}"; shift 2;;
    --ns-runners) NS_RUN="${2:?}"; shift 2;;
    --secret-name) SECRET_NAME="${2:?}"; shift 2;;
    --github-token) GH_AUTH="${2:?}"; shift 2;;
    --auth) AUTH="${2:?}"; shift 2;;
    --github-app-id) APP_ID="${2:?}"; shift 2;;
    --installation-id) APP_INSTALL_ID="${2:?}"; shift 2;;
    --private-key-file) APP_KEY_FILE="${2:?}"; shift 2;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$REPO" ] && REPO="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$REPO" ] || { echo "ERROR: <owner/repo> required" >&2; usage; exit 2; }
[[ "$REPO" == */* ]] || { echo "ERROR: target must be owner/repo" >&2; exit 1; }
for b in az kubectl helm gh; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done
AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")
REPO_URL="https://github.com/$REPO"

# Resolve auth (never echo secrets).
if [ "$AUTH" = "app" ]; then
  [ -n "$APP_ID" ] && [ -n "$APP_INSTALL_ID" ] && [ -f "$APP_KEY_FILE" ] \
    || { echo "ERROR: --auth app needs --github-app-id, --installation-id and --private-key-file" >&2; exit 1; }
elif [ "$AUTH" = "token" ]; then
  [ -n "$GH_AUTH" ] || GH_AUTH="$(gh auth token 2>/dev/null)"
  [ -n "$GH_AUTH" ] || { echo "ERROR: no GitHub token (pass --github-token or run 'gh auth login')" >&2; exit 1; }
else
  echo "ERROR: --auth must be 'token' or 'app'" >&2; exit 2
fi

echo ">>> Repo: $REPO  scale-set: $SCALE_SET (runs-on label)  min/max: $MIN/$MAX"

# 1. Provision AKS (optional).
if [ "$PROVISION" = "true" ]; then
  echo ">>> Provisioning AKS '$AKS' in '$RG' ($LOCATION)... (~6 min)"
  az group create -n "$RG" -l "$LOCATION" "${AZ_SUB[@]}" --output none || { echo "ERROR: az group create failed" >&2; exit 1; }
  az aks create -g "$RG" -n "$AKS" -l "$LOCATION" "${AZ_SUB[@]}" \
    --node-count 1 --node-vm-size "$NODE_SIZE" --generate-ssh-keys --tier free \
    --output none || { echo "ERROR: az aks create failed" >&2; exit 1; }
fi

echo ">>> Fetching kubeconfig..."
az aks get-credentials -g "$RG" -n "$AKS" "${AZ_SUB[@]}" --overwrite-existing >/dev/null 2>&1 \
  || { echo "ERROR: az aks get-credentials failed (cluster exists? use --provision)" >&2; exit 1; }
kubectl get nodes >/dev/null 2>&1 || { echo "ERROR: cannot reach the cluster API" >&2; exit 1; }

# 2. Install the ARC controller.
echo ">>> Installing ARC controller in '$NS_CTL'..."
helm install arc --namespace "$NS_CTL" --create-namespace "$CTRL_CHART" >/dev/null 2>&1 \
  || helm upgrade arc --namespace "$NS_CTL" "$CTRL_CHART" >/dev/null 2>&1 \
  || { echo "ERROR: controller helm install failed" >&2; exit 1; }
kubectl -n "$NS_CTL" rollout status deploy -l app.kubernetes.io/name=gha-rs-controller --timeout=120s >/dev/null 2>&1 || true

# 3. Create the auth secret (credentials only inside the cluster).
echo ">>> Creating namespace '$NS_RUN' and auth secret '$SECRET_NAME' (auth=$AUTH)..."
kubectl create namespace "$NS_RUN" >/dev/null 2>&1 || true
kubectl -n "$NS_RUN" delete secret "$SECRET_NAME" >/dev/null 2>&1 || true
if [ "$AUTH" = "app" ]; then
  kubectl -n "$NS_RUN" create secret generic "$SECRET_NAME" \
    --from-literal=github_app_id="$APP_ID" \
    --from-literal=github_app_installation_id="$APP_INSTALL_ID" \
    --from-file=github_app_private_key="$APP_KEY_FILE" >/dev/null 2>&1 \
    || { echo "ERROR: app secret creation failed" >&2; exit 1; }
else
  kubectl -n "$NS_RUN" create secret generic "$SECRET_NAME" \
    --from-literal=github_token="$GH_AUTH" >/dev/null 2>&1 \
    || { echo "ERROR: secret creation failed" >&2; exit 1; }
fi

# 4. Deploy the runner scale set.
echo ">>> Deploying runner scale set '$SCALE_SET'..."
helm install "$SCALE_SET" --namespace "$NS_RUN" --create-namespace \
  --set githubConfigUrl="$REPO_URL" \
  --set githubConfigSecret="$SECRET_NAME" \
  --set runnerScaleSetName="$SCALE_SET" \
  --set minRunners="$MIN" --set maxRunners="$MAX" \
  "$SS_CHART" >/dev/null 2>&1 \
  || { echo "ERROR: scale set helm install failed" >&2; exit 1; }

# 5. Verify the listener registered.
echo ">>> Waiting for the listener to register (up to 120s)..."
ok=""
for _ in $(seq 1 24); do
  if kubectl -n "$NS_CTL" get pods 2>/dev/null | grep -q "$SCALE_SET.*listener.*Running"; then ok="yes"; break; fi
  sleep 5
done
kubectl -n "$NS_CTL" get pods 2>/dev/null | grep -i listener | sed 's/^/    /'
if [ -n "$ok" ]; then
  echo ">>> ARC is up. Workflows can target  runs-on: $SCALE_SET"
  echo ">>> Verify with: arc-verify.sh $REPO --scale-set $SCALE_SET"
else
  echo "WARN: listener not observed Running yet. Check: kubectl -n $NS_CTL get pods; kubectl -n $NS_CTL logs -l app.kubernetes.io/component=runner-scale-set-listener" >&2
fi
