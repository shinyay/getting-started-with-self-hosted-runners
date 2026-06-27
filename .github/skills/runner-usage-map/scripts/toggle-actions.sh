#!/usr/bin/env bash
#
# toggle-actions.sh - switch a repo's GitHub Actions between Active and
# Non-active. Toggles repo-level Actions (enable/disable) and/or individual
# workflows. PREVIEW (dry-run) by default; --apply performs the change.
#
# Usage:
#   toggle-actions.sh --repo OWNER/REPO [--repo ...] <action> [--apply]
# Actions (choose one or more):
#   --disable-actions / --enable-actions       repo-level Actions on/off
#   --disable-workflow NAME|ID                 a single workflow off
#   --enable-workflow  NAME|ID                 a single workflow on
# Options:
#   --apply            actually perform the change (default: preview only)
#   --protect LIST     comma-separated owner/repo to refuse (default: this repo)
#   --help
#
# Safety: PREVIEW by default; refuses any repo in the protect list; prints the
# exact API call; idempotent. Never prints secrets.

set -euo pipefail

REPOS=(); APPLY=0
DIS_ACTIONS=0; EN_ACTIONS=0; DIS_WF=""; EN_WF=""
PROTECT=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)             REPOS+=("${2:?}"); shift 2;;
    --disable-actions)  DIS_ACTIONS=1; shift;;
    --enable-actions)   EN_ACTIONS=1; shift;;
    --disable-workflow) DIS_WF="${2:?}"; shift 2;;
    --enable-workflow)  EN_WF="${2:?}"; shift 2;;
    --apply)            APPLY=1; shift;;
    --protect)          PROTECT="${2:?}"; shift 2;;
    -h|--help)          usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found" >&2; exit 1; }
[ ${#REPOS[@]} -gt 0 ] || { echo "ERROR: pass at least one --repo" >&2; exit 2; }
if [ "$DIS_ACTIONS" = 1 ] && [ "$EN_ACTIONS" = 1 ]; then
  echo "ERROR: --disable-actions and --enable-actions are mutually exclusive" >&2; exit 2; fi
if [ "$DIS_ACTIONS$EN_ACTIONS" = "00" ] && [ -z "$DIS_WF" ] && [ -z "$EN_WF" ]; then
  echo "ERROR: choose an action (--disable-actions / --enable-actions / --disable-workflow / --enable-workflow)" >&2; exit 2; fi

# Auto-protect the repo you are running from (forks get real self-protection,
# not the upstream template name). --protect APPENDS more; the auto-protected
# repo is always kept. Matching is case-insensitive (GitHub folds case).
DEFAULT_PROTECT="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
PROTECT_ALL="$(printf '%s' "$DEFAULT_PROTECT,$PROTECT" | sed 's/^,//; s/,$//')"
PROTECT_LC="$(printf '%s' "$PROTECT_ALL" | tr '[:upper:]' '[:lower:]')"

[ "$APPLY" = 1 ] && MODE="APPLY" || MODE="PREVIEW"
echo ">>> Mode: $MODE  (protect: ${PROTECT_ALL:-none})"

is_protected() {
  local lc; lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case ",$PROTECT_LC," in *",$lc,"*) return 0;; *) return 1;; esac
}

run() {  # run <METHOD> <path> [<field=val>...]
  local method="$1" path="$2"; shift 2
  echo "    $method $path $*"
  [ "$APPLY" = 1 ] || return 0
  if gh api -X "$method" "$path" "$@" >/dev/null 2>&1; then
    echo "    -> done"
  else
    echo "    -> FAILED (gh api $method $path)" >&2
    FAILED=1
  fi
}

# Resolve a workflow name/id to its numeric id.
resolve_wf() {
  local repo="$1" key="$2"
  if printf '%s' "$key" | grep -qE '^[0-9]+$'; then printf '%s' "$key"; return; fi
  gh api "repos/$repo/actions/workflows" \
    --jq ".workflows[] | select(.name==\"$key\" or (.path|endswith(\"/$key\")) or .path==\".github/workflows/$key\") | .id" 2>/dev/null | head -1
}

for r in "${REPOS[@]}"; do
  echo ">>> $r"
  if is_protected "$r"; then echo "    REFUSED (protected). Use --protect to change."; continue; fi

  if [ "$DIS_ACTIONS" = 1 ]; then
    cur="$(gh api "repos/$r/actions/permissions" --jq .enabled 2>/dev/null || echo unknown)"
    if [ "$cur" = "false" ]; then echo "    Actions already disabled (no-op)";
    else run PUT "repos/$r/actions/permissions" -F enabled=false; fi
  fi
  if [ "$EN_ACTIONS" = 1 ]; then
    cur="$(gh api "repos/$r/actions/permissions" --jq .enabled 2>/dev/null || echo unknown)"
    if [ "$cur" = "true" ]; then echo "    Actions already enabled (no-op)";
    else run PUT "repos/$r/actions/permissions" -F enabled=true; fi
  fi
  if [ -n "$DIS_WF" ]; then
    id="$(resolve_wf "$r" "$DIS_WF")"
    if [ -n "$id" ]; then run PUT "repos/$r/actions/workflows/$id/disable";
    else echo "    workflow '$DIS_WF' not found" >&2; FAILED=1; fi
  fi
  if [ -n "$EN_WF" ]; then
    id="$(resolve_wf "$r" "$EN_WF")"
    if [ -n "$id" ]; then run PUT "repos/$r/actions/workflows/$id/enable";
    else echo "    workflow '$EN_WF' not found" >&2; FAILED=1; fi
  fi
done

[ "$APPLY" = 1 ] || echo ">>> PREVIEW only — re-run with --apply to perform these changes."
if [ "$APPLY" = 1 ] && [ "${FAILED:-0}" = 1 ]; then
  echo ">>> One or more requested workflow toggles could not be resolved." >&2
  exit 1
fi
