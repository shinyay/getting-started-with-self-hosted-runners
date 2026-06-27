#!/usr/bin/env bash
#
# vm-up.sh — provision an Azure VM self-hosted runner via Bicep + cloud-init.
#
# Generates (or accepts) an SSH key, mints a registration token, and deploys
# bicep/vm-runner/main.bicep. cloud-init installs and registers the runner as a
# systemd service a few minutes after the deployment returns.
#
# Usage:
#   vm-up.sh <owner/repo> [options]
# Options:
#   --rg RG                 resource group (default: rg-vm-runner)
#   --create-rg             create the resource group first
#   --location LOC          Azure region (default: eastus)
#   --vm-name NAME          VM name (default: ghrunner-vm-01)
#   --vm-size SIZE          VM size (default: Standard_B2s)
#   --runner-name NAME      runner display name (default: same as --vm-name)
#   --labels LABELS         runner labels (default: azure,linux,x64,vm)
#   --ssh-key PATH          SSH public key file (default: generate an ephemeral key)
#   --allowed-ssh-source S  NSG SSH source CIDR (default: this host's public IP /32)
#   --template PATH         Bicep template (default: bicep/vm-runner/main.bicep)
#   --subscription ID       az subscription (never az account set)
#   --help
# The registration token is passed as a @secure Bicep param and never echoed.

set -uo pipefail

RG="rg-vm-runner"; CREATE_RG="false"; LOCATION="eastus"
VM_NAME="ghrunner-vm-01"; VM_SIZE="Standard_B2s"; RUNNER_NAME=""
LABELS="azure,linux,x64,vm"; SSH_KEY=""; ALLOWED_SSH=""; SUBSCRIPTION=""
TEMPLATE="bicep/vm-runner/main.bicep"; REPO=""
TMPKEYDIR=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
cleanup() { [ -n "$TMPKEYDIR" ] && rm -rf "$TMPKEYDIR"; }
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --rg) RG="${2:?}"; shift 2;;
    --create-rg) CREATE_RG="true"; shift;;
    --location) LOCATION="${2:?}"; shift 2;;
    --vm-name) VM_NAME="${2:?}"; shift 2;;
    --vm-size) VM_SIZE="${2:?}"; shift 2;;
    --runner-name) RUNNER_NAME="${2:?}"; shift 2;;
    --labels) LABELS="${2:?}"; shift 2;;
    --ssh-key) SSH_KEY="${2:?}"; shift 2;;
    --allowed-ssh-source) ALLOWED_SSH="${2:?}"; shift 2;;
    --template) TEMPLATE="${2:?}"; shift 2;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$REPO" ] && REPO="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$REPO" ] || { echo "ERROR: <owner/repo> required" >&2; usage; exit 2; }
[[ "$REPO" == */* ]] || { echo "ERROR: target must be owner/repo" >&2; exit 1; }
for b in az gh; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done
[ -f "$TEMPLATE" ] || { echo "ERROR: Bicep template not found: $TEMPLATE" >&2; exit 1; }
[ -n "$RUNNER_NAME" ] || RUNNER_NAME="$VM_NAME"
AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

# 1. SSH public key (generate an ephemeral keypair if none provided).
if [ -z "$SSH_KEY" ]; then
  command -v ssh-keygen >/dev/null 2>&1 || { echo "ERROR: ssh-keygen needed to generate a key (or pass --ssh-key)" >&2; exit 1; }
  TMPKEYDIR="$(mktemp -d)"
  ssh-keygen -t ed25519 -f "$TMPKEYDIR/id" -N "" -q
  SSH_KEY="$TMPKEYDIR/id.pub"
  echo ">>> Generated an ephemeral SSH key (discarded on exit)."
fi
[ -f "$SSH_KEY" ] || { echo "ERROR: SSH public key not found: $SSH_KEY" >&2; exit 1; }
SSH_PUB="$(cat "$SSH_KEY")"

# 2. Allowed SSH source (default: this host's public IP /32).
if [ -z "$ALLOWED_SSH" ]; then
  MYIP="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
  ALLOWED_SSH="${MYIP:+$MYIP/32}"; ALLOWED_SSH="${ALLOWED_SSH:-*}"
fi
echo ">>> Repo: $REPO  VM: $VM_NAME ($VM_SIZE)  runner: $RUNNER_NAME  labels: $LABELS"
echo ">>> SSH source allowed: $ALLOWED_SSH"

# 3. Mint a registration token (1h TTL — used by cloud-init within minutes).
REG_TOK="$(gh api "repos/$REPO/actions/runners/registration-token" -X POST --jq '.token' 2>/dev/null)"
[ -n "$REG_TOK" ] || { echo "ERROR: could not mint registration token (need repo admin)" >&2; exit 1; }

# 4. Resource group.
if [ "$CREATE_RG" = "true" ]; then
  az group create -n "$RG" -l "$LOCATION" "${AZ_SUB[@]}" --output none || { echo "ERROR: az group create failed" >&2; exit 1; }
fi

# 5. Deploy the Bicep (token + key passed as parameters; not echoed).
echo ">>> Deploying VM via Bicep (this provisions VNet/NSG/identity/PIP/NIC/VM)..."
DEPLOY_NAME="vm-runner-$(date +%Y%m%d-%H%M%S)"
az deployment group create -g "$RG" "${AZ_SUB[@]}" --name "$DEPLOY_NAME" \
  --template-file "$TEMPLATE" \
  --parameters \
    location="$LOCATION" vmName="$VM_NAME" vmSize="$VM_SIZE" \
    sshPublicKey="$SSH_PUB" githubUrl="https://github.com/$REPO" \
    runnerToken="$REG_TOK" runnerName="$RUNNER_NAME" runnerLabels="$LABELS" \
    allowedSshSource="$ALLOWED_SSH" \
  --query "properties.outputs.publicIpAddress.value" -o tsv > /tmp/vmip.$$ 2>/tmp/vmerr.$$ \
  || { echo "ERROR: az deployment group create failed:" >&2; cat /tmp/vmerr.$$ >&2; rm -f /tmp/vmip.$$ /tmp/vmerr.$$; exit 1; }
VMIP="$(cat /tmp/vmip.$$ 2>/dev/null)"; rm -f /tmp/vmip.$$ /tmp/vmerr.$$

echo ">>> VM deployed. Public IP: ${VMIP:-?}"
echo ">>> The runner registers via cloud-init (~5-10 min). Poll:"
echo "      gh api repos/$REPO/actions/runners --jq '.runners[]|{name,status}'"
echo ">>> Then verify: vm-verify.sh $REPO --runner $RUNNER_NAME --labels $LABELS"
