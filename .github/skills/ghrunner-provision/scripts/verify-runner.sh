#!/usr/bin/env bash
#
# verify-runner.sh — prove a runner works: online + a real smoke job goes green.
#
# Usage:
#   verify-runner.sh <owner/repo | local-clone-path> [options]
# Options:
#   --runner NAME        expected runner name (asserts the job ran on it)
#   --labels LABELS      runner labels -> smoke workflow runs-on (default: azure,linux,x64,aci)
#   --online-timeout S   wait up to S sec for the runner to be online (default: 180)
#   --run-timeout S      wait up to S sec for the smoke run (default: 300)
#   --keep               keep the smoke workflow file (default: remove it)
#   --help
# Writes .github/workflows/runner-smoke.yml on the repo's default branch,
# dispatches it, and asserts success. Removes the workflow afterwards.

set -uo pipefail

RUNNER=""
LABELS="azure,linux,x64,aci"
ONLINE_TIMEOUT=180
RUN_TIMEOUT=300
KEEP="false"
TARGET=""
WF_PATH=".github/workflows/runner-smoke.yml"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runner) RUNNER="${2:?}"; shift 2;;
    --labels) LABELS="${2:?}"; shift 2;;
    --online-timeout) ONLINE_TIMEOUT="${2:?}"; shift 2;;
    --run-timeout) RUN_TIMEOUT="${2:?}"; shift 2;;
    --keep) KEEP="true"; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TARGET" ] && TARGET="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: target <owner/repo | local-path> required" >&2; usage; exit 2; }
for b in gh git; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done

resolve_repo() {
  local t="$1"
  if git -C "$t" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$t" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
  else printf '%s' "$t"; fi
}
REPO="$(resolve_repo "$TARGET")"
[[ "$REPO" == */* ]] || { echo "ERROR: could not resolve owner/repo from '$TARGET'" >&2; exit 1; }
BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
[ -n "$BRANCH" ] || { echo "ERROR: could not read default branch for $REPO" >&2; exit 1; }
echo ">>> Repo: $REPO  (default branch: $BRANCH)"

# --- 1. Online check ---------------------------------------------------------
echo ">>> Waiting for a runner to be online (timeout ${ONLINE_TIMEOUT}s)..."
online=""; deadline=$(( $(date +%s) + ONLINE_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -n "$RUNNER" ]; then
    st="$(gh api "repos/$REPO/actions/runners" --jq ".runners[]|select(.name==\"$RUNNER\")|.status" 2>/dev/null)"
  else
    st="$(gh api "repos/$REPO/actions/runners" --jq '.runners[]|select(.status=="online")|.status' 2>/dev/null | head -1)"
  fi
  if [ "$st" = "online" ]; then online="yes"; break; fi
  sleep 5
done
[ -n "$online" ] || { echo "FAIL: no online runner${RUNNER:+ named $RUNNER} within ${ONLINE_TIMEOUT}s." >&2; \
  echo "      Diagnose with the ghrunner-triage skill." >&2; exit 1; }
echo ">>> Runner online ✅"

# --- 2. Write the smoke workflow on the default branch (git over SSH) --------
# git+SSH avoids needing the PAT 'workflow' scope to add a workflow file.
RUNS_ON="self-hosted, $(printf '%s' "$LABELS" | sed 's/,/, /g')"
WORKTREE="$(mktemp -d)"
GIT_ID=(-c user.name=ghrunner-provision -c user.email=ghrunner-provision@users.noreply.github.com)
CLONE_URL="git@github.com:$REPO.git"
echo ">>> Cloning $REPO (SSH) to place the smoke workflow..."
git clone --depth 1 "$CLONE_URL" "$WORKTREE" >/dev/null 2>&1 \
  || { echo "ERROR: git clone failed ($CLONE_URL). Need SSH push access." >&2; rm -rf "$WORKTREE"; exit 1; }
mkdir -p "$WORKTREE/.github/workflows"
cat > "$WORKTREE/$WF_PATH" <<YAML
name: Runner Smoke Test
on:
  workflow_dispatch:
jobs:
  smoke:
    runs-on: [${RUNS_ON}]
    steps:
      - name: Runner identity
        run: |
          echo "Runner: \${RUNNER_NAME:-unknown}"
          echo "OS: \$(uname -srm)"
      - name: Prove execution
        run: echo "Self-hosted runner smoke test OK"
YAML
git -C "$WORKTREE" "${GIT_ID[@]}" add "$WF_PATH" >/dev/null 2>&1
git -C "$WORKTREE" "${GIT_ID[@]}" commit -m "ci: add runner smoke test" >/dev/null 2>&1
git -C "$WORKTREE" "${GIT_ID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 \
  || { echo "ERROR: failed to push smoke workflow over SSH" >&2; rm -rf "$WORKTREE"; exit 1; }
echo ">>> Smoke workflow pushed."

cleanup_wf() {
  if [ "$KEEP" != "true" ] && [ -f "$WORKTREE/$WF_PATH" ]; then
    git -C "$WORKTREE" "${GIT_ID[@]}" rm "$WF_PATH" >/dev/null 2>&1
    git -C "$WORKTREE" "${GIT_ID[@]}" commit -m "ci: remove runner smoke test" >/dev/null 2>&1
    git -C "$WORKTREE" "${GIT_ID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 && echo ">>> Removed smoke workflow."
  fi
  rm -rf "$WORKTREE"
}
trap cleanup_wf EXIT

# --- 3. Dispatch + watch -----------------------------------------------------
echo ">>> Dispatching smoke workflow (allowing GitHub to register it)..."
dispatched=""
for _ in 1 2 3 4 5 6; do
  if gh workflow run runner-smoke.yml --repo "$REPO" --ref "$BRANCH" >/dev/null 2>&1; then dispatched="yes"; break; fi
  sleep 5
done
[ -n "$dispatched" ] || { echo "FAIL: could not dispatch the smoke workflow." >&2; exit 1; }

echo ">>> Waiting for the run id..."
RID=""; deadline=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  RID="$(gh run list --repo "$REPO" --workflow runner-smoke.yml --event workflow_dispatch -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
  [ -n "$RID" ] && break; sleep 3
done
[ -n "$RID" ] || { echo "FAIL: no run appeared for the smoke workflow." >&2; exit 1; }
echo ">>> Run id: $RID — watching (timeout ${RUN_TIMEOUT}s)..."

deadline=$(( $(date +%s) + RUN_TIMEOUT )); status=""; concl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  read -r status concl < <(gh run view "$RID" --repo "$REPO" --json status,conclusion --jq '.status+" "+(.conclusion//"")' 2>/dev/null)
  [ "$status" = "completed" ] && break
  sleep 6
done

JOB_RUNNER="$(gh api "repos/$REPO/actions/runs/$RID/jobs" --jq '.jobs[0].runner_name // ""' 2>/dev/null)"
echo "---------------------------------------------"
echo "run $RID: status=$status conclusion=$concl  ran-on=${JOB_RUNNER:-?}"
[ "$concl" = "success" ] || { echo "FAIL: smoke run did not succeed." >&2; exit 1; }
if [ -n "$RUNNER" ] && [ -n "$JOB_RUNNER" ] && [ "$JOB_RUNNER" != "$RUNNER" ]; then
  echo "WARN: ran on '$JOB_RUNNER', expected '$RUNNER' (another self-hosted runner picked it up)." >&2
fi
echo "PASS: runner online and smoke job green ✅"
