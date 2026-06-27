#!/usr/bin/env bash
#
# monitor-down.sh - tear down the Azure Monitor resources created by
# monitor-up.sh and return cost to zero.
#
# Removes the diagnostic settings from the target container group(s), then
# deletes the dedicated monitor resource group wholesale (Log Analytics
# workspace + action group + metric alert all live there).
#
# Usage:
#   monitor-down.sh --subscription ID [options] --yes
# Options:
#   --monitor-rg RG        dedicated RG to delete (default: rg-runner-monitor)
#   --target-rg RG         RG whose ACI hold the diagnostic settings (default: ghrunner-rg)
#   --target-container N   only this container group (default: all in target-rg)
#   --yes                  confirm destructive deletion
#   --help
# Safety: REFUSES to delete the ACI fleet RG. --monitor-rg must NOT be the
# target RG / ghrunner-rg. Deletes diagnostic settings only (never the ACI).
# Never runs `az account set`.

set -euo pipefail

SUBSCRIPTION=""
MON_RG="rg-runner-monitor"
TARGET_RG="ghrunner-rg"
TARGET_CONTAINER=""
YES=0
DIAG_NAME="ghrunner-health-diag"
PROTECTED="ghrunner-rg"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --subscription)     SUBSCRIPTION="${2:?}"; shift 2;;
    --monitor-rg)       MON_RG="${2:?}"; shift 2;;
    --target-rg)        TARGET_RG="${2:?}"; shift 2;;
    --target-container) TARGET_CONTAINER="${2:?}"; shift 2;;
    --yes)              YES=1; shift;;
    -h|--help)          usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "ERROR: az not found" >&2; exit 1; }
# Pass --subscription AFTER each command (this env's az mis-parses it as a
# global pre-command arg); never run `az account set`.
SUB_ARGS=()
[ -n "$SUBSCRIPTION" ] && SUB_ARGS=(--subscription "$SUBSCRIPTION")

# Hard guard: never delete the fleet RG.
if [ "$MON_RG" = "$PROTECTED" ] || [ "$MON_RG" = "$TARGET_RG" ]; then
  echo "ERROR: refusing to delete '$MON_RG' (it is the protected/target ACI RG)." >&2
  echo "       --monitor-rg must be a dedicated monitoring RG." >&2
  exit 1
fi

if [ "$YES" != 1 ]; then
  echo "This will DELETE diagnostic settings from ACI in '$TARGET_RG' and delete" >&2
  echo "the monitoring RG '$MON_RG' (Log Analytics + alerts). Re-run with --yes." >&2
  exit 2
fi

echo ">>> Removing diagnostic settings '$DIAG_NAME' from target ACI in '$TARGET_RG'..."
if [ -n "$TARGET_CONTAINER" ]; then
  IDS="$(az container show -g "$TARGET_RG" -n "$TARGET_CONTAINER" "${SUB_ARGS[@]}" --query id -o tsv 2>/dev/null || true)"
else
  IDS="$(az container list -g "$TARGET_RG" "${SUB_ARGS[@]}" --query '[].id' -o tsv 2>/dev/null || true)"
fi
for id in $IDS; do
  az monitor diagnostic-settings delete --name "$DIAG_NAME" --resource "$id" "${SUB_ARGS[@]}" -o none 2>/dev/null \
    && echo "    - ${id##*/}" || true
done

echo ">>> Deleting monitor RG '$MON_RG' (Log Analytics workspace + action group + alert)..."
az group delete -n "$MON_RG" "${SUB_ARGS[@]}" --yes -o none

echo ">>> Monitoring torn down. Cost returned to zero ('$MON_RG' deleted)."
