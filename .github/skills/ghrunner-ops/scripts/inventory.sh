#!/usr/bin/env bash
#
# inventory.sh — read-only reconciliation of the ACI self-hosted runner fleet.
#
# Parses the container->repo map from docs/runner-registry.md, then compares the
# ledger against live Azure (state, EPHEMERAL, image tag, restartCount) and
# GitHub (runner status/busy). Flags drift. Performs NO mutations.
#
# Usage:
#   inventory.sh [-g|--resource-group RG] [--subscription ID] [--registry PATH]
#   inventory.sh --help
#
# Guardrails: never runs `az account set`. To target another subscription pass
# --subscription; ~/.azure may be shared with other sessions.

set -euo pipefail

RG="ghrunner-rg"
SUBSCRIPTION=""
REGISTRY=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RG="${2:?}"; shift 2;;
    --subscription)      SUBSCRIPTION="${2:?}"; shift 2;;
    --registry)          REGISTRY="${2:?}"; shift 2;;
    -h|--help)           usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

for bin in az gh grep awk sed python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done

if [ -z "$REGISTRY" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
  REGISTRY="$ROOT/docs/runner-registry.md"
fi
[ -f "$REGISTRY" ] || { echo "ERROR: registry not found: $REGISTRY" >&2; exit 1; }

AZ_SUB=()
[ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

# Preflight: the resource group must be reachable (do NOT az account set).
if ! az group show -n "$RG" "${AZ_SUB[@]}" --query name -o tsv >/dev/null 2>&1; then
  echo "ERROR: cannot reach resource group '$RG'." >&2
  echo "       The active subscription is likely wrong. Pass --subscription <id>." >&2
  echo "       Never run 'az account set' (it breaks other concurrent sessions)." >&2
  exit 1
fi

printf '%-17s %-9s %-7s %-16s %-5s | %-42s %-9s %s\n' \
  Container ACIstate rc Image EPH Repository GH DRIFT
printf '%0.s-' {1..120}; echo

total=0; az_running=0; gh_online=0; drift=0

while IFS= read -r line; do
  c="$(printf '%s' "$line"  | grep -oE 'ghrunner-aci-[0-9]+' | head -1)"
  slug="$(printf '%s' "$line" | grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -1 | sed -E 's#github\.com/##')"
  [ -n "$c" ] && [ -n "$slug" ] || continue
  total=$((total+1))

  # Ledger Status cell (last table column).
  status_cell="$(printf '%s' "$line" | awk -F'|' '{print $(NF-1)}' | sed 's/^ *//; s/ *$//')"

  # Live Azure: one JSON call, parsed with python3 ('|'-delimited, empty-safe).
  state="MISSING"; rpolicy=""; image=""; rc=""; eph=""
  if azjson="$(az container show -g "$RG" -n "$c" "${AZ_SUB[@]}" -o json 2>/dev/null)"; then
    parsed="$(printf '%s' "$azjson" | python3 -c '
import sys, json
d = json.load(sys.stdin)
c0 = (d.get("containers") or [{}])[0]
ev = {e["name"]: e.get("value") for e in (c0.get("environmentVariables") or [])}
iv = c0.get("instanceView") or {}
print("|".join([
    (d.get("instanceView") or {}).get("state") or "",
    d.get("restartPolicy") or "",
    c0.get("image") or "",
    str(iv.get("restartCount", "")),
    str(ev.get("EPHEMERAL", "")),
]))' 2>/dev/null || true)"
    [ -n "$parsed" ] && IFS='|' read -r state rpolicy image rc eph <<<"$parsed"
  fi
  tag="${image##*:}"; shortimg="${image##*/}"
  [ "$state" = "Running" ] && az_running=$((az_running+1))

  # Live GitHub: is a runner of this name registered, and its status/busy?
  ghinfo="$(gh api "repos/$slug/actions/runners" \
              --jq ".runners[] | select(.name==\"$c\") | \"\(.status)/\(.busy)\"" 2>/dev/null || true)"
  [ -z "$ghinfo" ] && ghinfo="-/-"
  case "$ghinfo" in online/*) gh_online=$((gh_online+1));; esac

  # Drift detection.
  flags=""
  [ "$state" = "MISSING" ] && flags="$flags MISSING-IN-AZURE"
  [ "$ghinfo" = "-/-" ]   && flags="$flags NOT-REGISTERED"
  if [ "$eph" = "true" ] && ! printf '%s' "$status_cell" | grep -qi 'ephemeral'; then
    flags="$flags EPH-UNLOGGED"
  fi
  if [ -n "$tag" ] && [ "$tag" != "latest" ] && [ -n "$status_cell" ] \
     && ! printf '%s' "$status_cell" | grep -qF "$tag"; then
    flags="$flags VER-DRIFT($tag)"
  fi
  [ -n "$flags" ] && drift=$((drift+1)) || flags=" ok"

  printf '%-17s %-9s %-7s %-16s %-5s | %-42s %-9s %s\n' \
    "$c" "${state:-?}" "${rc:-?}" "${shortimg:-?}" "${eph:-?}" "$slug" "$ghinfo" "${flags# }"
done < <(grep -E '^\| `ghrunner-aci-[0-9]+`' "$REGISTRY")

echo
echo "Summary: ${total} in ledger | ${az_running} Running in Azure | ${gh_online} online in GitHub | ${drift} with drift"
[ "$drift" -eq 0 ] && echo "No drift detected." || echo "Review rows flagged above; reflect fixes into ${REGISTRY}."
