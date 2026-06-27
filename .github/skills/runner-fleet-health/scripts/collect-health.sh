#!/usr/bin/env bash
#
# collect-health.sh - gather live fleet-health facts and emit the normalized
# health document (JSON) on stdout. Strictly READ-ONLY: only `az ... show/list`
# and `gh api` GETs, then hands raw output to normalize_health.py.
#
# Usage:
#   collect-health.sh [-g|--resource-group RG] [--subscription ID]
#                     [--repo OWNER/REPO]... [--fleet] [--registry PATH]
#   collect-health.sh --help
#
# Targets (at least one required):
#   -g/--resource-group  audit ACI container runtime state (uses `az container show`)
#   --repo               a repo's runners + recent runs (repeatable)
#   --fleet              derive the repo list from the registry ledger
# Guardrail: never runs `az account set` (~/.azure may be shared).

set -euo pipefail

RG=""
SUBSCRIPTION=""
REGISTRY=""
FLEET=0
REPOS=()

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RG="${2:?}"; shift 2;;
    --subscription)      SUBSCRIPTION="${2:?}"; shift 2;;
    --repo)              REPOS+=("${2:?}"); shift 2;;
    --fleet)             FLEET=1; shift;;
    --registry)          REGISTRY="${2:?}"; shift 2;;
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

AZ_SUB=()
[ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NORM_ARGS=(--registry "$REGISTRY")

# --- ACI container runtime state (read-only; `show` for accurate state) ---
if [ -n "$RG" ]; then
  command -v az >/dev/null 2>&1 || { echo "ERROR: az not found" >&2; exit 1; }
  if ! az group show -n "$RG" "${AZ_SUB[@]}" --query name -o tsv >/dev/null 2>&1; then
    echo "ERROR: cannot reach resource group '$RG'. Pass --subscription <id>." >&2
    echo "       Never run 'az account set' (it breaks other concurrent sessions)." >&2
    exit 1
  fi
  mapfile -t NAMES < <(az container list -g "$RG" "${AZ_SUB[@]}" --query '[].name' -o tsv 2>/dev/null || true)
  echo '[' > "$TMP/containers.json"
  first=1
  for n in "${NAMES[@]}"; do
    [ -n "$n" ] || continue
    obj="$(az container show -g "$RG" -n "$n" "${AZ_SUB[@]}" -o json \
      --query '{name:name, state:containers[0].instanceView.currentState.state, restart_count:containers[0].instanceView.restartCount, restart_policy:restartPolicy, image:containers[0].image, eph:containers[0].environmentVariables[?name==`EPHEMERAL`].value|[0]}' 2>/dev/null || echo '{}')"
    [ "$first" = 1 ] || echo ',' >> "$TMP/containers.json"
    printf '%s' "$obj" >> "$TMP/containers.json"
    first=0
  done
  echo ']' >> "$TMP/containers.json"
  NORM_ARGS+=(--containers "$TMP/containers.json")
fi

# --- repos: explicit --repo and/or --fleet (from the ledger) ---
if [ "$FLEET" = 1 ] && [ -f "$REGISTRY" ]; then
  mapfile -t LEDGER < <(grep -oE 'github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' "$REGISTRY" | sed 's#github.com/##' | sort -u)
  REPOS+=("${LEDGER[@]}")
fi

if [ ${#REPOS[@]} -gt 0 ]; then
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found" >&2; exit 1; }
  printf '%s\n' "${REPOS[@]}" | awk 'NF' | sort -u > "$TMP/repos.txt"
  echo '[' > "$TMP/repospec.json"
  first=1
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    slug="$(printf '%s' "$repo" | tr '/.' '__')"
    gh api "repos/$repo/actions/runners" > "$TMP/$slug.runners.json" 2>/dev/null || echo '{}' > "$TMP/$slug.runners.json"
    gh api "repos/$repo/actions/runs?per_page=20" > "$TMP/$slug.runs.json" 2>/dev/null || echo '{}' > "$TMP/$slug.runs.json"
    entry="$(REPO="$repo" RUNNERS="$TMP/$slug.runners.json" RUNS="$TMP/$slug.runs.json" \
      python3 -c 'import json,os;print(json.dumps({"full_name":os.environ["REPO"],"runners":os.environ["RUNNERS"],"runs":os.environ["RUNS"]}))')"
    [ "$first" = 1 ] || echo ',' >> "$TMP/repospec.json"
    printf '%s' "$entry" >> "$TMP/repospec.json"
    first=0
  done < "$TMP/repos.txt"
  echo ']' >> "$TMP/repospec.json"
  NORM_ARGS+=(--repo-spec "$TMP/repospec.json")
fi

python3 "$HERE/normalize_health.py" "${NORM_ARGS[@]}"
