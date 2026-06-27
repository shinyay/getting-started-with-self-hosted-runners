#!/usr/bin/env bash
#
# vm-down.sh — decommission an Azure VM self-hosted runner.
#
# Deregisters the runner from GitHub, then either deletes the dedicated resource
# group (--delete-rg) or the VM and its named resources. Repository deletion is
# Human-in-the-Loop (--show-repo-delete prints the command, never runs it).
#
# Usage:
#   vm-down.sh [options]
# Options:
#   --rg RG               resource group (default: rg-vm-runner)
#   --vm-name NAME        VM name (default: ghrunner-vm-01) — for per-resource delete
#   --repo owner/repo     repo to deregister the runner from / HITL hint
#   --runner NAME         runner name to deregister (default: --vm-name)
#   --delete-rg           az group delete the whole RG (dedicated RGs only)
#   --show-repo-delete    print the HITL repo-delete command (never runs it)
#   --subscription ID     az subscription (never az account set)
#   --yes                 confirm destructive actions
#   --help
# Safety: --delete-rg refuses the ACI fleet RG 'ghrunner-rg'.

set -uo pipefail

RG="rg-vm-runner"; VM_NAME="ghrunner-vm-01"; REPO=""; RUNNER=""
DELETE_RG="false"; SHOW_REPO_DELETE="false"; SUBSCRIPTION=""; YES="false"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
need_yes() { [ "$YES" = "true" ] || { echo "Refusing destructive action without --yes: $1" >&2; exit 3; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rg) RG="${2:?}"; shift 2;;
    --vm-name) VM_NAME="${2:?}"; shift 2;;
    --repo) REPO="${2:?}"; shift 2;;
    --runner) RUNNER="${2:?}"; shift 2;;
    --delete-rg) DELETE_RG="true"; shift;;
    --show-repo-delete) SHOW_REPO_DELETE="true"; shift;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    --yes) YES="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "ERROR: 'az' not found" >&2; exit 1; }
AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")
[ -n "$RUNNER" ] || RUNNER="$VM_NAME"

# 1. Deregister the runner from GitHub.
if [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  RID="$(gh api "repos/$REPO/actions/runners" --jq ".runners[]|select(.name==\"$RUNNER\")|.id" 2>/dev/null || true)"
  if [ -n "$RID" ]; then
    gh api -X DELETE "repos/$REPO/actions/runners/$RID" >/dev/null 2>&1 && echo ">>> Deregistered runner $RUNNER." || echo "WARN: could not deregister $RUNNER."
  else
    echo ">>> Runner $RUNNER not registered (already gone)."
  fi
fi

# 2a. Delete the whole RG (guarded), or 2b. delete the VM + named resources.
if [ "$DELETE_RG" = "true" ]; then
  if [ "$RG" = "ghrunner-rg" ]; then
    echo "ERROR: refusing to delete the ACI fleet resource group 'ghrunner-rg'." >&2; exit 3
  fi
  need_yes "delete resource group $RG (the VM and all its resources)"
  az group delete -n "$RG" "${AZ_SUB[@]}" --yes --no-wait >/dev/null 2>&1 \
    && echo ">>> Deleting resource group '$RG' (async)." || echo "WARN: could not start deletion of '$RG'."
else
  need_yes "delete VM '$VM_NAME' and its named resources in '$RG'"
  echo ">>> Deleting VM '$VM_NAME' and associated resources in '$RG'..."
  az vm delete -g "$RG" -n "$VM_NAME" "${AZ_SUB[@]}" --yes >/dev/null 2>&1 && echo "    deleted VM" || echo "    VM not found"
  for res in \
    "network nic ${VM_NAME}-nic" \
    "network public-ip ${VM_NAME}-pip" \
    "network vnet ${VM_NAME}-vnet" \
    "network nsg ${VM_NAME}-nsg" \
    "identity ${VM_NAME}-identity"; do
    set -- $res
    if [ "$1" = "identity" ]; then
      az identity delete -g "$RG" -n "$2" "${AZ_SUB[@]}" >/dev/null 2>&1 && echo "    deleted identity $2" || true
    else
      az "$1" "$2" delete -g "$RG" -n "$3" "${AZ_SUB[@]}" >/dev/null 2>&1 && echo "    deleted $2 $3" || true
    fi
  done
  # OS disk (name is generated; delete any disk tagged to this VM best-effort).
  for d in $(az disk list -g "$RG" "${AZ_SUB[@]}" --query "[?starts_with(name, '${VM_NAME}')].name" -o tsv 2>/dev/null); do
    az disk delete -g "$RG" -n "$d" "${AZ_SUB[@]}" --yes >/dev/null 2>&1 && echo "    deleted disk $d" || true
  done
fi

# 3. Repository deletion is Human-in-the-Loop.
if [ "$SHOW_REPO_DELETE" = "true" ] && [ -n "$REPO" ]; then
  echo ">>> Repository deletion is a Human-in-the-Loop step — run it yourself:"
  echo "      web UI : https://github.com/$REPO/settings  (Danger Zone -> Delete this repository)"
  echo "      or CLI : gh repo delete $REPO --yes"
fi

echo ">>> VM teardown complete."
