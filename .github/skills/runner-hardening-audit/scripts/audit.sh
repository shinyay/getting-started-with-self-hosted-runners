#!/usr/bin/env bash
#
# audit.sh - run a read-only security-hardening audit of the self-hosted runner
# fleet and print a scorecard (Markdown by default, or JSON).
#
# Pipeline: collect.sh (live, read-only) -> audit_rules.py (pure rule engine).
# It never mutates Azure or GitHub and never prints secret values; remediation
# is printed for you to review and apply yourself (Human-in-the-Loop).
#
# Usage:
#   audit.sh [-g|--resource-group RG] [--subscription ID] [--repo OWNER/REPO]
#            [--registry PATH] [--json] [--strict] [--out FILE]
#   audit.sh --help
#
# Scope: pass --resource-group to audit the ACI fleet, --repo to audit a
# repository's Actions settings, or both. Exit code is non-zero on any FAIL
# (with --strict, also on WARN) so it can gate CI.
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
    --registry)          PASS_ARGS+=(--registry "${2:?}"); shift 2;;
    --json)              RULE_ARGS+=(--json); shift;;
    --strict)            RULE_ARGS+=(--strict); shift;;
    --out)               OUT="${2:?}"; shift 2;;
    -h|--help)           usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

DOC="$(bash "$HERE/collect.sh" "${PASS_ARGS[@]}")"

if [ -n "$OUT" ]; then
  printf '%s' "$DOC" | python3 "$HERE/audit_rules.py" "${RULE_ARGS[@]}" | tee "$OUT"
  rc=${PIPESTATUS[1]}
else
  printf '%s' "$DOC" | python3 "$HERE/audit_rules.py" "${RULE_ARGS[@]}"
  rc=${PIPESTATUS[1]}
fi
exit "$rc"
