#!/usr/bin/env bash
#
# collect-usage.sh - gather live cross-repo runner-usage facts and emit the
# normalized usage document (JSON) on stdout. Strictly READ-ONLY: only `gh repo
# list` and `gh api` GETs. Hands raw output to normalize_usage.py.
#
# Usage:
#   collect-usage.sh [--owner OWNER] [--limit N] [--repo OWNER/REPO]...
#                    [--active-days N] [--no-runson]
#                    [--include-archived] [--include-forks]
#   collect-usage.sh --help
#
# Default: your owned, non-archived, non-fork repos. Pass --repo to target
# specific repos (skips listing). --no-runson skips workflow-file fetches (fast,
# classifies by registered runners only).

set -euo pipefail

OWNER=""; LIMIT=100; ACTIVE_DAYS=30; NO_RUNSON=0; INC_ARCHIVED=0; INC_FORKS=0
REPOS=()

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)            OWNER="${2:?}"; shift 2;;
    --limit)            LIMIT="${2:?}"; shift 2;;
    --repo)             REPOS+=("${2:?}"); shift 2;;
    --active-days)      ACTIVE_DAYS="${2:?}"; shift 2;;
    --no-runson)        NO_RUNSON=1; shift;;
    --include-archived) INC_ARCHIVED=1; shift;;
    --include-forks)    INC_FORKS=1; shift;;
    -h|--help)          usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

for bin in gh jq python3 base64; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found" >&2; exit 1; }
done
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "$OWNER" ] || OWNER="$(gh api user --jq .login 2>/dev/null)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- build the list of target repos (full owner/name) ---
declare -a TARGETS=()
if [ ${#REPOS[@]} -gt 0 ]; then
  TARGETS=("${REPOS[@]}")
else
  filt='.[]'
  [ "$INC_ARCHIVED" = 0 ] && filt="$filt | select(.isArchived==false)"
  [ "$INC_FORKS" = 0 ] && filt="$filt | select(.isFork==false)"
  mapfile -t TARGETS < <(gh repo list "$OWNER" --limit "$LIMIT" \
    --json nameWithOwner,visibility,isArchived,isFork 2>/dev/null \
    | jq -r "$filt | .nameWithOwner")
fi
[ ${#TARGETS[@]} -gt 0 ] || { echo "ERROR: no repos to scan for owner '$OWNER'" >&2; exit 1; }
echo ">>> scanning ${#TARGETS[@]} repo(s)..." >&2

# --- per-repo collection (read-only) ---
echo '[' > "$TMP/spec.json"; first=1
for r in "${TARGETS[@]}"; do
  [ -n "$r" ] || continue
  slug="$(printf '%s' "$r" | tr '/.' '__')"
  base="$TMP/$slug"
  vis="$(gh repo view "$r" --json visibility --jq .visibility 2>/dev/null || echo unknown)"
  gh api "repos/$r/actions/permissions" > "$base.perm.json" 2>/dev/null || echo '{}' > "$base.perm.json"
  gh api "repos/$r/actions/workflows" > "$base.workflows.json" 2>/dev/null || echo '{"workflows":[]}' > "$base.workflows.json"
  gh api "repos/$r/actions/runners" > "$base.runners.json" 2>/dev/null || echo '{"runners":[]}' > "$base.runners.json"
  gh api "repos/$r/actions/runs?per_page=1" > "$base.lastrun.json" 2>/dev/null || echo '{"workflow_runs":[]}' > "$base.lastrun.json"

  NW="$(jq '.workflows | length' "$base.workflows.json" 2>/dev/null || echo 0)"
  for ((idx=0; idx<NW; idx++)); do
    fpath="$base.wf.$idx"
    if [ "$NO_RUNSON" = 0 ]; then
      p="$(jq -r ".workflows[$idx].path" "$base.workflows.json")"
      gh api "repos/$r/contents/$p" --jq .content 2>/dev/null | base64 -d > "$fpath" 2>/dev/null || : > "$fpath"
    else
      : > "$fpath"
    fi
  done

  entry="$(R="$r" VIS="$vis" BASE="$base" python3 - <<'PY'
import json, os
r, vis, base = os.environ["R"], os.environ["VIS"], os.environ["BASE"]
wf = json.load(open(base + ".workflows.json"))
wf_files = []
for idx, w in enumerate(wf.get("workflows", []) or []):
    wf_files.append({"name": w.get("name"), "path": w.get("path"),
                     "state": w.get("state"), "file": "%s.wf.%d" % (base, idx)})
print(json.dumps({"name": r, "visibility": vis,
                  "permissions": base + ".perm.json",
                  "runners": base + ".runners.json",
                  "lastrun": base + ".lastrun.json",
                  "wf_files": wf_files}))
PY
)"
  [ "$first" = 1 ] || echo ',' >> "$TMP/spec.json"
  printf '%s' "$entry" >> "$TMP/spec.json"; first=0
done
echo ']' >> "$TMP/spec.json"

python3 "$HERE/normalize_usage.py" --repo-spec "$TMP/spec.json" \
  --owner "$OWNER" --active-days "$ACTIVE_DAYS"
