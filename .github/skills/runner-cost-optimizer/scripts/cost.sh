#!/usr/bin/env bash
#
# cost.sh - read-only cost-optimization report for the self-hosted runner fleet.
# Prints per-runner monthly cost, utilization and right-sizing / scale-to-zero
# recommendations with savings estimates (Markdown by default, or JSON).
#
# Pipeline: collect-cost.sh (live, read-only) -> cost_rules.py (pure engine).
# It never mutates anything and never prints secret values. All monetary figures
# are estimates (see references/pricing.md).
#
# Usage:
#   cost.sh [-g|--resource-group RG] [--subscription ID]
#           [--repo OWNER/REPO]... [--fleet] [--registry PATH]
#           [--live-prices] [--region R] [--vcpu-rate R] [--mem-rate R]
#           [--baseline-cpu C] [--baseline-mem M]
#           [--low-util P] [--very-low-util P] [--high-util P] [--offhours-save F]
#           [--json] [--strict] [--out FILE]
#   cost.sh --help
#
# Guardrail: never runs `az account set` (~/.azure may be shared).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS_ARGS=(); RULE_ARGS=(); OUT=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) PASS_ARGS+=(--resource-group "${2:?}"); shift 2;;
    --subscription)      PASS_ARGS+=(--subscription "${2:?}"); shift 2;;
    --repo)              PASS_ARGS+=(--repo "${2:?}"); shift 2;;
    --fleet)             PASS_ARGS+=(--fleet); shift;;
    --registry)          PASS_ARGS+=(--registry "${2:?}"); shift 2;;
    --live-prices)       PASS_ARGS+=(--live-prices); shift;;
    --region)            PASS_ARGS+=(--region "${2:?}"); shift 2;;
    --vcpu-rate)         PASS_ARGS+=(--vcpu-rate "${2:?}"); shift 2;;
    --mem-rate)          PASS_ARGS+=(--mem-rate "${2:?}"); shift 2;;
    --baseline-cpu)      PASS_ARGS+=(--baseline-cpu "${2:?}"); shift 2;;
    --baseline-mem)      PASS_ARGS+=(--baseline-mem "${2:?}"); shift 2;;
    --low-util)          PASS_ARGS+=(--low-util "${2:?}"); shift 2;;
    --very-low-util)     PASS_ARGS+=(--very-low-util "${2:?}"); shift 2;;
    --high-util)         PASS_ARGS+=(--high-util "${2:?}"); shift 2;;
    --offhours-save)     PASS_ARGS+=(--offhours-save "${2:?}"); shift 2;;
    --json)              RULE_ARGS+=(--json); shift;;
    --strict)            RULE_ARGS+=(--strict); shift;;
    --out)               OUT="${2:?}"; shift 2;;
    -h|--help)           usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

DOC="$(bash "$HERE/collect-cost.sh" "${PASS_ARGS[@]}")"

if [ -n "$OUT" ]; then
  printf '%s' "$DOC" | python3 "$HERE/cost_rules.py" "${RULE_ARGS[@]}" | tee "$OUT"
  rc=${PIPESTATUS[1]}
else
  printf '%s' "$DOC" | python3 "$HERE/cost_rules.py" "${RULE_ARGS[@]}"
  rc=${PIPESTATUS[1]}
fi
exit "$rc"
