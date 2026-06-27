#!/usr/bin/env bash
#
# monitor-up.sh - OPT-IN, COSTED: provision Azure Monitor for the runner fleet.
#
# Creates a DEDICATED resource group (default rg-runner-monitor) holding a Log
# Analytics workspace + an action group + an ACI metric alert, and attaches a
# diagnostic setting on the target container group(s) -> the workspace. Tear it
# all down with monitor-down.sh to return cost to zero.
#
# Usage:
#   monitor-up.sh --subscription ID [options] --yes
# Options:
#   --monitor-rg RG        dedicated RG to create (default: rg-runner-monitor)
#   --location LOC         region (default: eastus)
#   --workspace NAME       Log Analytics workspace (default: ghrunner-logs)
#   --target-rg RG         RG holding the ACI to monitor (default: ghrunner-rg)
#   --target-container N   monitor only this container group (default: all in target-rg)
#   --action-email ADDR    add an email receiver to the action group (optional)
#   --yes                  confirm (this provisions billable resources)
#   --help
# Guardrail: never runs `az account set`. Records no secrets; fetches no keys.

set -euo pipefail

SUBSCRIPTION=""
MON_RG="rg-runner-monitor"
LOCATION="eastus"
WORKSPACE="ghrunner-logs"
TARGET_RG="ghrunner-rg"
TARGET_CONTAINER=""
ACTION_EMAIL=""
YES=0
DIAG_NAME="ghrunner-health-diag"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --subscription)     SUBSCRIPTION="${2:?}"; shift 2;;
    --monitor-rg)       MON_RG="${2:?}"; shift 2;;
    --location)         LOCATION="${2:?}"; shift 2;;
    --workspace)        WORKSPACE="${2:?}"; shift 2;;
    --target-rg)        TARGET_RG="${2:?}"; shift 2;;
    --target-container) TARGET_CONTAINER="${2:?}"; shift 2;;
    --action-email)     ACTION_EMAIL="${2:?}"; shift 2;;
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

if [ "$YES" != 1 ]; then
  echo "This provisions BILLABLE Azure Monitor resources in '$MON_RG':" >&2
  echo "  - Log Analytics workspace '$WORKSPACE' (ingestion/retention cost)" >&2
  echo "  - action group + ACI metric alert + diagnostic settings" >&2
  echo "Re-run with --yes to proceed. Tear down with monitor-down.sh to stop cost." >&2
  exit 2
fi

echo ">>> Creating dedicated monitor RG '$MON_RG' ($LOCATION)..."
az group create -n "$MON_RG" -l "$LOCATION" "${SUB_ARGS[@]}" -o none

echo ">>> Creating Log Analytics workspace '$WORKSPACE'..."
az monitor log-analytics workspace create \
  -g "$MON_RG" -n "$WORKSPACE" -l "$LOCATION" "${SUB_ARGS[@]}" -o none
WS_ID="$(az monitor log-analytics workspace show -g "$MON_RG" -n "$WORKSPACE" "${SUB_ARGS[@]}" --query id -o tsv)"

echo ">>> Creating action group 'ghrunner-health-ag'..."
AG_ARGS=(monitor action-group create -g "$MON_RG" -n ghrunner-health-ag --short-name ghhealth -o none)
[ -n "$ACTION_EMAIL" ] && AG_ARGS+=(--action email ops "$ACTION_EMAIL")
az "${AG_ARGS[@]}" "${SUB_ARGS[@]}"
AG_ID="$(az monitor action-group show -g "$MON_RG" -n ghrunner-health-ag "${SUB_ARGS[@]}" --query id -o tsv)"

# Resolve target ACI container-group resource ids.
echo ">>> Resolving target container group(s) in '$TARGET_RG'..."
if [ -n "$TARGET_CONTAINER" ]; then
  TARGETS="$(az container show -g "$TARGET_RG" -n "$TARGET_CONTAINER" "${SUB_ARGS[@]}" --query id -o tsv)"
else
  TARGETS="$(az container list -g "$TARGET_RG" "${SUB_ARGS[@]}" --query '[].id' -o tsv)"
fi
[ -n "$TARGETS" ] || { echo "ERROR: no target container groups found" >&2; exit 1; }

echo ">>> Creating ACI CPU metric alert 'ghrunner-cpu-alert'..."
# shellcheck disable=SC2086
az monitor metrics alert create \
  -g "$MON_RG" -n ghrunner-cpu-alert \
  --scopes $TARGETS \
  --condition "avg CpuUsage > 80" \
  --window-size 5m --evaluation-frequency 1m \
  --description "Runner ACI sustained high CPU" \
  --action "$AG_ID" "${SUB_ARGS[@]}" -o none \
  || echo "WARN: metric alert creation failed (continuing)" >&2

echo ">>> Attaching diagnostic settings '$DIAG_NAME' -> workspace (best-effort)..."
for id in $TARGETS; do
  az monitor diagnostic-settings create \
    --name "$DIAG_NAME" --resource "$id" --workspace "$WS_ID" \
    --metrics '[{"category":"AllMetrics","enabled":true}]' "${SUB_ARGS[@]}" -o none 2>/dev/null \
    && echo "    + ${id##*/}" \
    || echo "    ! ${id##*/}: diagnostic settings not supported/failed (skipped)" >&2
done

echo ">>> Monitoring is UP in '$MON_RG'."
echo ">>> Tear down (return cost to zero):"
echo "      monitor-down.sh --subscription <SUB> --monitor-rg $MON_RG --target-rg $TARGET_RG${TARGET_CONTAINER:+ --target-container $TARGET_CONTAINER} --yes"
