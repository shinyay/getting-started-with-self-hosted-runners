#!/usr/bin/env bash
#
# triage.sh — read-only triage of a failed self-hosted runner job.
#
# Fetches the failed step logs (and, for ACI runners, container logs), matches
# them against the failure catalog signatures, and prints the matched IDs with a
# recommended handoff. Performs NO mutations and applies NO fixes.
#
# Usage:
#   triage.sh <owner/repo> <run-id>        # triage a specific run
#   triage.sh --latest-failed <owner/repo> # triage the most recent failed run
#   triage.sh --stdin                      # classify a pasted log from stdin
#   triage.sh --help
# Options:
#   --resource-group RG   ACI resource group (default: ghrunner-rg)
#   --subscription ID     az subscription for ACI logs (never runs az account set)
#
# Look matched IDs up in references/failure-catalog.md for cause + handoff.

set -uo pipefail

RG="ghrunner-rg"
SUBSCRIPTION=""
MODE=""
REPO=""
RUN_ID=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --latest-failed) MODE="latest"; REPO="${2:?owner/repo required}"; shift 2;;
    --stdin)         MODE="stdin"; shift;;
    --resource-group) RG="${2:?}"; shift 2;;
    --subscription)  SUBSCRIPTION="${2:?}"; shift 2;;
    -h|--help)       usage; exit 0;;
    -*)              echo "Unknown option: $1" >&2; usage; exit 2;;
    *)
      if [ -z "$REPO" ]; then REPO="$1";
      elif [ -z "$RUN_ID" ]; then RUN_ID="$1";
      else echo "Unexpected argument: $1" >&2; exit 2; fi
      shift;;
  esac
done

[ -z "$MODE" ] && { [ -n "$REPO" ] && [ -n "$RUN_ID" ] && MODE="run" || { usage; exit 2; }; }

AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

BUF="$(mktemp)"; trap 'rm -f "$BUF"' EXIT
RUNNER=""; FAILED_JOB=""; FAILED_STEP=""; RUN_STATUS=""

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 1; }; }

if [ "$MODE" = "stdin" ]; then
  cat > "$BUF"
else
  need gh
  if [ "$MODE" = "latest" ]; then
    RUN_ID="$(gh run list --repo "$REPO" --status failure -L 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    [ -n "$RUN_ID" ] || { echo "No failed run found for $REPO." >&2; exit 1; }
  fi
  RUN_STATUS="$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion --jq '.status+"/"+(.conclusion//"")' 2>/dev/null || true)"
  meta="$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" \
            --jq '.jobs[] | select(.conclusion=="failure")
                  | [.name, (.runner_name//""), ((.steps[]? | select(.conclusion=="failure") | .name) // "")]
                  | @tsv' 2>/dev/null | head -1 || true)"
  IFS=$'\t' read -r FAILED_JOB RUNNER FAILED_STEP <<<"$meta"
  gh run view "$RUN_ID" --repo "$REPO" --log-failed > "$BUF" 2>/dev/null || true
  # ACI runners: append container logs for extra evidence (best-effort).
  if [[ "$RUNNER" =~ ^ghrunner-aci-[0-9]+$ ]] && command -v az >/dev/null 2>&1; then
    az container logs -g "$RG" -n "$RUNNER" "${AZ_SUB[@]}" >> "$BUF" 2>/dev/null || true
  fi
fi

echo "=== triage report ==="
[ "$MODE" != "stdin" ] && printf 'repo:%s  run:%s  status:%s\n' "$REPO" "$RUN_ID" "${RUN_STATUS:-?}"
[ -n "$FAILED_JOB" ] && printf 'failed job:%s  step:%s  runner:%s\n' "$FAILED_JOB" "${FAILED_STEP:-?}" "${RUNNER:-?}"
echo "---------------------"

matches=0
sig() { # id  regex  label
  if grep -iEq -- "$2" "$BUF"; then
    printf '  [%-22s] %s\n' "$1" "$3"; matches=$((matches+1))
  fi
}

# IMAGE
sig IMG-LSB        'lsb_release: command not found|gpg: command not found' 'runner image missing lsb-release/gnupg -> image >= v0.6.2-lsb-fix (A4+A3)'
sig IMG-CHROMIUM   'libnss3|libgbm1|libasound2'                            'Chromium libs missing -> image >= v0.6.1 (A4+A3)'
sig IMG-GH         'gh: command not found'                                 'GitHub CLI missing -> image >= v0.5.0 (A4+A3)'
sig IMG-LIBYAML    'libyaml'                                               'libyaml missing for setup-ruby -> image >= v0.4.0 (A4+A3)'
sig IMG-NODE24     'node24'                                                'runner < 2.327 (no node24) -> image >= v0.3.0 (A4+A3)'
sig IMG-TOOLCACHE  '/opt/hostedtoolcache'                                  'hostedtoolcache perms -> image >= v0.2.0 (A4+A3)'
# AUTH
sig AUTH-TOKEN-TTL    '[Ii]nvalid.*registration token|registration token.*(expired|invalid)' 'registration token expired -> redeploy (A3) or GH_PAT image (A6)'
sig AUTH-PRIVATE-REPO 'Repository not found'                              'private-repo GITHUB_TOKEN scope -> move to ARC (docs/16)'
sig AUTH-ARC-CREDS    'CrashLoopBackOff'                                  'ARC pod crashloop -> recreate GitHub App secret (docs/09,16)'
# WORKFLOW
sig WF-UNRELATED-HISTORIES 'refusing to merge unrelated histories'        'non-ephemeral dirty _work -> EPHEMERAL=true (A3/A2; docs/15 #3)'
sig WF-FIREWALL           'agent firewall|blocked by the firewall'        'agent firewall ON -> disable it (docs/15 #2)'
sig WF-SETUP-NODE-NOVER   'Version input is not set|node-version'         'setup-node lacks node-version -> pin node-version'
# INFRA
sig INF-DISK         'No space left on device'                            'disk full -> clean _work/ (docs/12); prefer ephemeral'
sig INF-DNS          'Could not resolve host|Temporary failure in name resolution|getaddrinfo' 'DNS/egress -> check resolv.conf/NSG (docs/12,04)'
sig INF-RESOURCE     'OOMKilled|Cannot allocate memory|exceeded the maximum execution time'    'OOM/timeout -> resize cpu/memory (docs/12)'
sig INF-ARC-PENDING  '0/[0-9]+ nodes are available|FailedScheduling'      'ARC pods pending -> node pool/autoscaler (docs/09)'
sig INF-AKS-STOPPED  'no such host'                                       'AKS API unreachable: cluster Stopped -> az aks start (docs/09,16)'

# Metadata-only hint: job never ran (queued / no runner) -> label/group mismatch.
if [ "$MODE" != "stdin" ] && [ ! -s "$BUF" ]; then
  if printf '%s' "${RUN_STATUS}" | grep -qi 'queued' || [ -z "$RUNNER" ]; then
    printf '  [%-22s] %s\n' "CFG-LABEL" 'no failed logs and run not picked up -> runs-on vs runner labels (docs/15); also check CFG-RUNNER-GROUP'
    matches=$((matches+1))
  fi
fi

echo "---------------------"
if [ "$matches" -eq 0 ]; then
  echo "No known signature matched."
  echo "Collect evidence manually: see references/diagnostics.md"
else
  echo "$matches signature(s) matched. Look IDs up in references/failure-catalog.md;"
  echo "apply fixes via the ghrunner-ops skill (A2/A3/A4/A6) — this script changes nothing."
fi
