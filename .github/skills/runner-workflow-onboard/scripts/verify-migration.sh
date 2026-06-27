#!/usr/bin/env bash
#
# verify-migration.sh — prove a migrated workflow runs green on a self-hosted runner.
#
# Dispatches a workflow_dispatch workflow in the repo, waits for a NEW run,
# and asserts conclusion=success and that it ran on a self-hosted runner.
#
# Usage:
#   verify-migration.sh <owner/repo | local-clone-path> --workflow FILE [options]
# Options:
#   --workflow FILE       workflow file name (e.g. ci.yml) — required
#   --runner NAME         expected runner name (assert the job ran on it)
#   --run-timeout S       max seconds to wait for the run (default: 420)
#   --help
# The workflow must have a `workflow_dispatch` trigger on the default branch.

set -uo pipefail

WORKFLOW=""; RUNNER=""; RUN_TIMEOUT=420; TARGET=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --workflow) WORKFLOW="${2:?}"; shift 2;;
    --runner) RUNNER="${2:?}"; shift 2;;
    --run-timeout) RUN_TIMEOUT="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TARGET" ] && TARGET="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: target <owner/repo | local-path> required" >&2; usage; exit 2; }
[ -n "$WORKFLOW" ] || { echo "ERROR: --workflow FILE required" >&2; usage; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: 'gh' not found" >&2; exit 1; }

resolve_repo() {
  local t="$1"
  if git -C "$t" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$t" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
  else printf '%s' "$t"; fi
}
REPO="$(resolve_repo "$TARGET")"
[[ "$REPO" == */* ]] || { echo "ERROR: could not resolve owner/repo from '$TARGET'" >&2; exit 1; }
BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
[ -n "$BRANCH" ] || { echo "ERROR: could not read default branch" >&2; exit 1; }
echo ">>> Repo: $REPO  workflow: $WORKFLOW  branch: $BRANCH"

PREV_RID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
echo ">>> Dispatching $WORKFLOW..."
dispatched=""
for _ in 1 2 3 4 5 6; do
  gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" >/dev/null 2>&1 && { dispatched="yes"; break; }
  sleep 5
done
[ -n "$dispatched" ] || { echo "FAIL: could not dispatch $WORKFLOW (has it a workflow_dispatch trigger on $BRANCH?)" >&2; exit 1; }

echo ">>> Waiting for a new run id..."
RID=""; deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  RID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
  [ -n "$RID" ] && [ "$RID" != "$PREV_RID" ] && break
  RID=""; sleep 3
done
[ -n "$RID" ] || { echo "FAIL: no new run appeared." >&2; exit 1; }
echo ">>> Run id: $RID — watching (timeout ${RUN_TIMEOUT}s)..."

deadline=$(( $(date +%s) + RUN_TIMEOUT )); status=""; concl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  read -r status concl < <(gh run view "$RID" --repo "$REPO" --json status,conclusion --jq '.status+" "+(.conclusion//"")' 2>/dev/null)
  [ "$status" = "completed" ] && break
  sleep 6
done
JOB_RUNNER="$(gh api "repos/$REPO/actions/runs/$RID/jobs" --jq '.jobs[0].runner_name // ""' 2>/dev/null)"
LABELS_SEEN="$(gh api "repos/$REPO/actions/runs/$RID/jobs" --jq '[.jobs[0].labels[]?] | join(",")' 2>/dev/null)"
echo "---------------------------------------------"
echo "run $RID: status=$status conclusion=$concl  ran-on=${JOB_RUNNER:-?}  labels=${LABELS_SEEN:-?}"
if [ "$concl" != "success" ]; then
  echo "FAIL: migrated workflow did not succeed." >&2
  echo "      View logs: gh run view $RID --repo $REPO --log-failed" >&2
  echo "      Diagnose with the ghrunner-triage skill." >&2
  exit 1
fi
case ",$LABELS_SEEN," in
  *,self-hosted,*) : ;;
  *) echo "WARN: job labels do not include self-hosted ($LABELS_SEEN) — did the migration target this workflow?" >&2;;
esac
[ -n "$RUNNER" ] && [ -n "$JOB_RUNNER" ] && [ "$JOB_RUNNER" != "$RUNNER" ] && \
  echo "WARN: ran on '$JOB_RUNNER', expected '$RUNNER'." >&2
echo "PASS: migrated workflow ran green on a self-hosted runner ✅"
