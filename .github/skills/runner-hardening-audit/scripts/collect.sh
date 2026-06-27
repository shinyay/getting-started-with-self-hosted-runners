#!/usr/bin/env bash
#
# collect.sh - gather the live security-relevant facts about the runner fleet
# and emit the normalized audit document (JSON) on stdout.
#
# Strictly READ-ONLY: it only runs `az ... show/list` and `gh api` GETs, then
# hands the raw output to normalize.py. It records environment-variable NAMES
# only and never prints a secret value.
#
# Usage:
#   collect.sh [-g|--resource-group RG] [--subscription ID]
#              [--repo OWNER/REPO] [--registry PATH]
#   collect.sh --help
#
# At least one of --resource-group (ACI fleet) or --repo (GitHub settings) is
# required. Guardrail: never runs `az account set` (~/.azure may be shared).

set -euo pipefail

RG=""
SUBSCRIPTION=""
REPO=""
REGISTRY=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RG="${2:?}"; shift 2;;
    --subscription)      SUBSCRIPTION="${2:?}"; shift 2;;
    --repo)              REPO="${2:?}"; shift 2;;
    --registry)          REGISTRY="${2:?}"; shift 2;;
    -h|--help)           usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

[ -n "$RG" ] || [ -n "$REPO" ] || { echo "ERROR: pass --resource-group and/or --repo" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$REGISTRY" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
  REGISTRY="$ROOT/docs/runner-registry.md"
fi

AZ_SUB=()
[ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NORM_ARGS=(--registry "$REGISTRY" --resource-group "$RG")

# --- ACI fleet (read-only) ---
if [ -n "$RG" ]; then
  command -v az >/dev/null 2>&1 || { echo "ERROR: az not found" >&2; exit 1; }
  if ! az group show -n "$RG" "${AZ_SUB[@]}" --query name -o tsv >/dev/null 2>&1; then
    echo "ERROR: cannot reach resource group '$RG'. Pass --subscription <id>." >&2
    echo "       Never run 'az account set' (it breaks other concurrent sessions)." >&2
    exit 1
  fi
  az container list -g "$RG" "${AZ_SUB[@]}" -o json > "$TMP/aci.json" 2>/dev/null || echo '[]' > "$TMP/aci.json"
  NORM_ARGS+=(--aci "$TMP/aci.json")
fi

# --- GitHub repo settings (read-only) ---
if [ -n "$REPO" ]; then
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found" >&2; exit 1; }
  gh api "repos/$REPO" > "$TMP/repo.json" 2>/dev/null || echo '{}' > "$TMP/repo.json"
  gh api "repos/$REPO/actions/permissions" > "$TMP/perm.json" 2>/dev/null || echo '{}' > "$TMP/perm.json"
  gh api "repos/$REPO/actions/permissions/workflow" > "$TMP/wf.json" 2>/dev/null || echo '{}' > "$TMP/wf.json"
  gh api "repos/$REPO/actions/runners" > "$TMP/runners.json" 2>/dev/null || echo '{}' > "$TMP/runners.json"
  NORM_ARGS+=(--repo-name "$REPO" --repo-meta "$TMP/repo.json" \
              --repo-perm "$TMP/perm.json" --repo-wf "$TMP/wf.json" \
              --repo-runners "$TMP/runners.json")
fi

python3 "$HERE/normalize.py" "${NORM_ARGS[@]}"
