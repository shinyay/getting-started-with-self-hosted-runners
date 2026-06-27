#!/usr/bin/env bash
#
# collect-cost.sh - gather live cost facts (ACI sizing + per-repo job history)
# and emit the normalized cost document (JSON) on stdout. Strictly READ-ONLY:
# only `az ... show/list` and `gh api` GETs, plus an optional public pricing
# fetch. Hands raw output to normalize_cost.py.
#
# Usage:
#   collect-cost.sh [-g|--resource-group RG] [--subscription ID]
#                   [--repo OWNER/REPO]... [--fleet] [--registry PATH]
#                   [--live-prices] [--region R] [--vcpu-rate R] [--mem-rate R]
#                   [--baseline-cpu C] [--baseline-mem M]
#                   [--low-util P] [--very-low-util P] [--high-util P]
#                   [--offhours-save F]
#   collect-cost.sh --help
#
# Guardrail: never runs `az account set`; passes --subscription AFTER commands.

set -euo pipefail

RG=""; SUBSCRIPTION=""; REGISTRY=""; FLEET=0; REPOS=()
LIVE_PRICES=0; REGION="eastus"; VCPU_RATE=""; MEM_RATE=""
BASE_CPU="1.0"; BASE_MEM="2.0"; LOW="15.0"; VLOW="10.0"; HIGH="60.0"; OFF="0.60"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RG="${2:?}"; shift 2;;
    --subscription)      SUBSCRIPTION="${2:?}"; shift 2;;
    --repo)              REPOS+=("${2:?}"); shift 2;;
    --fleet)             FLEET=1; shift;;
    --registry)          REGISTRY="${2:?}"; shift 2;;
    --live-prices)       LIVE_PRICES=1; shift;;
    --region)            REGION="${2:?}"; shift 2;;
    --vcpu-rate)         VCPU_RATE="${2:?}"; shift 2;;
    --mem-rate)          MEM_RATE="${2:?}"; shift 2;;
    --baseline-cpu)      BASE_CPU="${2:?}"; shift 2;;
    --baseline-mem)      BASE_MEM="${2:?}"; shift 2;;
    --low-util)          LOW="${2:?}"; shift 2;;
    --very-low-util)     VLOW="${2:?}"; shift 2;;
    --high-util)         HIGH="${2:?}"; shift 2;;
    --offhours-save)     OFF="${2:?}"; shift 2;;
    -h|--help)           usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

[ -n "$RG" ] || [ ${#REPOS[@]} -gt 0 ] || [ "$FLEET" = 1 ] || {
  echo "ERROR: pass --resource-group, --repo and/or --fleet" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$REGISTRY" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
  REGISTRY="$ROOT/docs/runner-registry.md"
fi
SUB_ARGS=()
[ -n "$SUBSCRIPTION" ] && SUB_ARGS=(--subscription "$SUBSCRIPTION")

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- pricing rates (static / live / override) ---
PRICE_ARGS=(--region "$REGION")
[ "$LIVE_PRICES" = 1 ] && PRICE_ARGS+=(--live)
[ -n "$VCPU_RATE" ] && PRICE_ARGS+=(--vcpu-rate "$VCPU_RATE")
[ -n "$MEM_RATE" ] && PRICE_ARGS+=(--mem-rate "$MEM_RATE")
python3 "$HERE/prices.py" "${PRICE_ARGS[@]}" > "$TMP/rates.json"

NORM_ARGS=(--registry "$REGISTRY" --rates "$TMP/rates.json" --region "$REGION"
           --baseline-cpu "$BASE_CPU" --baseline-mem "$BASE_MEM"
           --low-util "$LOW" --very-low-util "$VLOW" --high-util "$HIGH"
           --offhours-save "$OFF")

# --- ACI sizing (read-only) ---
if [ -n "$RG" ]; then
  command -v az >/dev/null 2>&1 || { echo "ERROR: az not found" >&2; exit 1; }
  if ! az group show -n "$RG" "${SUB_ARGS[@]}" --query name -o tsv >/dev/null 2>&1; then
    echo "ERROR: cannot reach resource group '$RG'. Pass --subscription <id>." >&2
    echo "       Never run 'az account set' (it breaks other concurrent sessions)." >&2
    exit 1
  fi
  mapfile -t NAMES < <(az container list -g "$RG" "${SUB_ARGS[@]}" --query '[].name' -o tsv 2>/dev/null || true)
  echo '[' > "$TMP/containers.json"; first=1
  for n in "${NAMES[@]}"; do
    [ -n "$n" ] || continue
    obj="$(az container show -g "$RG" -n "$n" "${SUB_ARGS[@]}" -o json \
      --query '{name:name, cpu:containers[0].resources.requests.cpu, memory_gb:containers[0].resources.requests.memoryInGb, restart_policy:restartPolicy, state:containers[0].instanceView.currentState.state, eph:containers[0].environmentVariables[?name==`EPHEMERAL`].value|[0]}' 2>/dev/null || echo '{}')"
    [ "$first" = 1 ] || echo ',' >> "$TMP/containers.json"
    printf '%s' "$obj" >> "$TMP/containers.json"; first=0
  done
  echo ']' >> "$TMP/containers.json"
  NORM_ARGS+=(--containers "$TMP/containers.json")
fi

# --- repos for utilization (--repo and/or --fleet) ---
if [ "$FLEET" = 1 ] && [ -f "$REGISTRY" ]; then
  mapfile -t LEDGER < <(grep -oE 'github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' "$REGISTRY" | sed 's#github.com/##' | sort -u)
  REPOS+=("${LEDGER[@]}")
fi
if [ ${#REPOS[@]} -gt 0 ]; then
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found" >&2; exit 1; }
  printf '%s\n' "${REPOS[@]}" | awk 'NF' | sort -u > "$TMP/repos.txt"
  echo '[' > "$TMP/repospec.json"; first=1
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    slug="$(printf '%s' "$repo" | tr '/.' '__')"
    gh api "repos/$repo/actions/runs?per_page=50" > "$TMP/$slug.runs.json" 2>/dev/null || echo '{}' > "$TMP/$slug.runs.json"
    entry="$(REPO="$repo" RUNS="$TMP/$slug.runs.json" \
      python3 -c 'import json,os;print(json.dumps({"full_name":os.environ["REPO"],"runs":os.environ["RUNS"]}))')"
    [ "$first" = 1 ] || echo ',' >> "$TMP/repospec.json"
    printf '%s' "$entry" >> "$TMP/repospec.json"; first=0
  done < "$TMP/repos.txt"
  echo ']' >> "$TMP/repospec.json"
  NORM_ARGS+=(--repo-spec "$TMP/repospec.json")
fi

python3 "$HERE/normalize_cost.py" "${NORM_ARGS[@]}"
