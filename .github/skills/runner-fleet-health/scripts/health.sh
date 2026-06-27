#!/usr/bin/env bash
#
# health.sh - on-demand fleet-health snapshot for the self-hosted runner fleet.
# Prints a HEALTHY/DEGRADED/UNHEALTHY scorecard (Markdown by default, or JSON).
#
# Pipeline: collect-health.sh (live, read-only) -> health_rules.py (pure engine).
# It never mutates anything and never prints secret values.
#
# Usage:
#   health.sh [-g|--resource-group RG] [--subscription ID]
#             [--repo OWNER/REPO]... [--fleet] [--registry PATH]
#             [--json] [--strict] [--out FILE]
#   health.sh --help
#
# Targets: pass -g for ACI runtime state, --repo/--fleet for GitHub runner &
# job signals, or any combination. Exit code is non-zero on UNHEALTHY (and on
# DEGRADED with --strict) so it can gate a cron/CI check.
#
# Guardrail: never runs `az account set` (~/.azure may be shared).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS_ARGS=()
RULE_ARGS=()
OUT=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) PASS_ARGS+=(--resource-group "${2:?}"); shift 2;;
    --subscription)      PASS_ARGS+=(--subscription "${2:?}"); shift 2;;
    --repo)              PASS_ARGS+=(--repo "${2:?}"); shift 2;;
    --fleet)             PASS_ARGS+=(--fleet); shift;;
    --registry)          PASS_ARGS+=(--registry "${2:?}"); shift 2;;
    --json)              RULE_ARGS+=(--json); shift;;
    --strict)            RULE_ARGS+=(--strict); shift;;
    --out)               OUT="${2:?}"; shift 2;;
    -h|--help)           usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

DOC="$(bash "$HERE/collect-health.sh" "${PASS_ARGS[@]}")"

if [ -n "$OUT" ]; then
  printf '%s' "$DOC" | python3 "$HERE/health_rules.py" "${RULE_ARGS[@]}" | tee "$OUT"
  rc=${PIPESTATUS[1]}
else
  printf '%s' "$DOC" | python3 "$HERE/health_rules.py" "${RULE_ARGS[@]}"
  rc=${PIPESTATUS[1]}
fi
exit "$rc"
