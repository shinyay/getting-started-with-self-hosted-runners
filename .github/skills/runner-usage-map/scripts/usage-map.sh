#!/usr/bin/env bash
#
# usage-map.sh - read-only cross-repo runner-usage census. Classifies each of
# your repos as GitHub-hosted / self-hosted / mixed / dynamic / none, reports
# Active status and flags (e.g. self-hosted-but-offline), and can suggest
# migrations. Output: Markdown (default), CSV or JSON.
#
# Pipeline: collect-usage.sh (live, read-only) -> classify.py (pure engine).
# Never mutates anything; never prints secret values.
#
# Usage:
#   usage-map.sh [--owner OWNER] [--limit N] [--repo OWNER/REPO]...
#                [--active-days N] [--no-runson]
#                [--include-archived] [--include-forks]
#                [--format md|csv|json] [--out FILE] [--strict]
#                [--suggest-migrations]
#   usage-map.sh --help

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS_ARGS=(); FMT="md"; OUT=""; STRICT=0; SUGGEST=0

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)            PASS_ARGS+=(--owner "${2:?}"); shift 2;;
    --limit)            PASS_ARGS+=(--limit "${2:?}"); shift 2;;
    --repo)             PASS_ARGS+=(--repo "${2:?}"); shift 2;;
    --active-days)      PASS_ARGS+=(--active-days "${2:?}"); shift 2;;
    --no-runson)        PASS_ARGS+=(--no-runson); shift;;
    --include-archived) PASS_ARGS+=(--include-archived); shift;;
    --include-forks)    PASS_ARGS+=(--include-forks); shift;;
    --format)           FMT="${2:?}"; shift 2;;
    --out)              OUT="${2:?}"; shift 2;;
    --strict)           STRICT=1; shift;;
    --suggest-migrations) SUGGEST=1; shift;;
    -h|--help)          usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

DOC="$(bash "$HERE/collect-usage.sh" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"})"

RULE_ARGS=(--format "$FMT")
[ "$STRICT" = 1 ] && RULE_ARGS+=(--strict)

# Disable -e around the classify pipeline so a --strict non-zero exit does not
# abort before the suggest block / final exit (we propagate rc ourselves).
set +e
if [ -n "$OUT" ]; then
  printf '%s' "$DOC" | python3 "$HERE/classify.py" "${RULE_ARGS[@]}" | tee "$OUT"
else
  printf '%s' "$DOC" | python3 "$HERE/classify.py" "${RULE_ARGS[@]}"
fi
rc=${PIPESTATUS[1]}
set -e

if [ "$SUGGEST" = 1 ]; then
  echo
  echo "## Suggested migrations (GitHub-hosted -> self-hosted, via runner-workflow-onboard)"
  printf '%s' "$DOC" | python3 "$HERE/classify.py" --format json \
    | jq -r '.rows[] | select(.flags | index("HOSTED_CANDIDATE")) | .repo' \
    | while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        echo "# $repo"
        echo "  bash .github/skills/runner-workflow-onboard/scripts/migrate-workflows.sh $repo   # preview; add --apply to migrate"
      done
fi

exit "$rc"
