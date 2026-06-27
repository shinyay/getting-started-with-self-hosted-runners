#!/usr/bin/env bash
#
# arc-down.sh — tear down ARC (and optionally the AKS cluster).
#
# Uninstalls the runner scale set and the ARC controller via Helm, and with
# --delete-cluster deletes the dedicated AKS resource group. Repository deletion
# is Human-in-the-Loop (--show-repo-delete prints the command, never runs it).
#
# Usage:
#   arc-down.sh [options]
# Options:
#   --scale-set NAME      Helm release / scale set to uninstall (default: arc-runner-set)
#   --ns-runners NS       runners namespace (default: arc-runners)
#   --ns-controller NS    controller namespace (default: arc-systems)
#   --controller-release  controller Helm release name (default: arc)
#   --delete-cluster      az group delete the AKS RG (needs --rg and --yes)
#   --rg RG               AKS resource group to delete (with --delete-cluster)
#   --repo owner/repo     repo for the HITL repo-delete hint
#   --show-repo-delete    print the HITL repo-delete command (never runs it)
#   --subscription ID     az subscription (never az account set)
#   --yes                 confirm destructive actions
#   --help
# Safety: --delete-cluster only ever deletes the RG named with --rg; it refuses
# to touch the ACI fleet RG 'ghrunner-rg'.

set -uo pipefail

SCALE_SET="arc-runner-set"; NS_RUN="arc-runners"; NS_CTL="arc-systems"
CTRL_RELEASE="arc"; DELETE_CLUSTER="false"; RG=""; REPO=""
SHOW_REPO_DELETE="false"; SUBSCRIPTION=""; YES="false"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
need_yes() { [ "$YES" = "true" ] || { echo "Refusing destructive action without --yes: $1" >&2; exit 3; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scale-set) SCALE_SET="${2:?}"; shift 2;;
    --ns-runners) NS_RUN="${2:?}"; shift 2;;
    --ns-controller) NS_CTL="${2:?}"; shift 2;;
    --controller-release) CTRL_RELEASE="${2:?}"; shift 2;;
    --delete-cluster) DELETE_CLUSTER="true"; shift;;
    --rg) RG="${2:?}"; shift 2;;
    --repo) REPO="${2:?}"; shift 2;;
    --show-repo-delete) SHOW_REPO_DELETE="true"; shift;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    --yes) YES="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

# 1. Uninstall the scale set + controller (best-effort; idempotent).
if command -v helm >/dev/null 2>&1; then
  helm uninstall "$SCALE_SET" -n "$NS_RUN" >/dev/null 2>&1 && echo ">>> Uninstalled scale set '$SCALE_SET'." || echo ">>> Scale set '$SCALE_SET' not installed."
  helm uninstall "$CTRL_RELEASE" -n "$NS_CTL" >/dev/null 2>&1 && echo ">>> Uninstalled controller '$CTRL_RELEASE'." || echo ">>> Controller '$CTRL_RELEASE' not installed."
fi

# 2. Delete the dedicated AKS resource group (guarded).
if [ "$DELETE_CLUSTER" = "true" ]; then
  [ -n "$RG" ] || { echo "ERROR: --delete-cluster requires --rg <name>" >&2; exit 2; }
  if [ "$RG" = "ghrunner-rg" ]; then
    echo "ERROR: refusing to delete the ACI fleet resource group 'ghrunner-rg'." >&2; exit 3
  fi
  need_yes "delete resource group $RG (AKS cluster and all its resources)"
  command -v az >/dev/null 2>&1 || { echo "ERROR: 'az' not found" >&2; exit 1; }
  az group delete -n "$RG" "${AZ_SUB[@]}" --yes --no-wait >/dev/null 2>&1 \
    && echo ">>> Deleting resource group '$RG' (async)." \
    || echo "WARN: could not start deletion of '$RG'."
fi

# 3. Repository deletion is Human-in-the-Loop.
if [ "$SHOW_REPO_DELETE" = "true" ] && [ -n "$REPO" ]; then
  echo ">>> Repository deletion is a Human-in-the-Loop step — run it yourself:"
  echo "      web UI : https://github.com/$REPO/settings  (Danger Zone -> Delete this repository)"
  echo "      or CLI : gh repo delete $REPO --yes"
fi

echo ">>> ARC teardown complete."
