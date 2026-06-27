#!/usr/bin/env bash
#
# vm-verify.sh — prove an Azure VM self-hosted runner runs a job green.
#
# Waits for the VM runner to register online (cloud-init can take several
# minutes), pushes a simple workflow_dispatch smoke workflow over git+SSH,
# dispatches it, and asserts conclusion=success on a self-hosted runner.
#
# Usage:
#   vm-verify.sh <owner/repo | local-clone-path> [options]
# Options:
#   --runner NAME         expected runner name (assert the job ran on it)
#   --labels LABELS       runs-on labels (default: azure,linux,x64,vm)
#   --online-timeout S    wait up to S sec for the runner online (default: 600)
#   --run-timeout S       max seconds to wait for the run (default: 420)
#   --keep                keep the smoke workflow (default: remove it)
#   --help

set -uo pipefail

RUNNER=""; LABELS="azure,linux,x64,vm"; ONLINE_TIMEOUT=600; RUN_TIMEOUT=420
KEEP="false"; TARGET=""
WF_PATH=".github/workflows/vm-smoke.yml"

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

[ -n "$TARGET" ] || { echo "ERROR: <owner/repo | local-path> required" >&2; usage; exit 2; }
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
[ -n "$BRANCH" ] || { echo "ERROR: could not read default branch" >&2; exit 1; }
echo ">>> Repo: $REPO  labels: $LABELS  branch: $BRANCH"

# 1. Wait for a runner to register online (cloud-init delay).
echo ">>> Waiting for the VM runner to register online (timeout ${ONLINE_TIMEOUT}s)..."
online=""; deadline=$(( $(date +%s) + ONLINE_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -n "$RUNNER" ]; then
    st="$(gh api "repos/$REPO/actions/runners" --jq ".runners[]|select(.name==\"$RUNNER\")|.status" 2>/dev/null)"
  else
    st="$(gh api "repos/$REPO/actions/runners" --jq '.runners[]|select(.status=="online")|.status' 2>/dev/null | head -1)"
  fi
  [ "$st" = "online" ] && { online="yes"; break; }
  sleep 10
done
[ -n "$online" ] || { echo "FAIL: no online runner${RUNNER:+ named $RUNNER} within ${ONLINE_TIMEOUT}s." >&2; \
  echo "      Check cloud-init on the VM (ssh + 'sudo cat /var/log/cloud-init-output.log'); diagnose with ghrunner-triage." >&2; exit 1; }
echo ">>> Runner online ✅"

# 2. Push a smoke workflow over git+SSH.
RUNS_ON="self-hosted, $(printf '%s' "$LABELS" | sed 's/,/, /g')"
WORKTREE="$(mktemp -d)"; trap 'rm -rf "$WORKTREE"' EXIT
GID=(-c user.name=vm-runner-ops -c user.email=vm-runner-ops@users.noreply.github.com)
git clone --depth 1 "git@github.com:$REPO.git" "$WORKTREE" >/dev/null 2>&1 \
  || { echo "ERROR: git clone failed; need SSH push access" >&2; exit 1; }
mkdir -p "$WORKTREE/.github/workflows"
cat > "$WORKTREE/$WF_PATH" <<YAML
name: VM Smoke Test
on:
  workflow_dispatch:
jobs:
  smoke:
    runs-on: [${RUNS_ON}]
    steps:
      - name: Runner identity
        run: |
          echo "Runner: \${RUNNER_NAME:-unknown}"
          echo "Host: \$(hostname)"
          echo "OS: \$(. /etc/os-release; echo \$PRETTY_NAME)"
      - name: Prove execution
        run: echo "VM self-hosted runner smoke OK"
YAML
git -C "$WORKTREE" "${GID[@]}" add "$WF_PATH" >/dev/null 2>&1
git -C "$WORKTREE" "${GID[@]}" commit -m "ci: add VM smoke test" >/dev/null 2>&1
git -C "$WORKTREE" "${GID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 \
  || { echo "ERROR: failed to push smoke workflow" >&2; exit 1; }
echo ">>> Pushed $WF_PATH"

cleanup_wf() {
  if [ "$KEEP" != "true" ] && [ -f "$WORKTREE/$WF_PATH" ]; then
    git -C "$WORKTREE" "${GID[@]}" rm "$WF_PATH" >/dev/null 2>&1
    git -C "$WORKTREE" "${GID[@]}" commit -m "ci: remove VM smoke test" >/dev/null 2>&1
    git -C "$WORKTREE" "${GID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 && echo ">>> Removed smoke workflow."
  fi
  rm -rf "$WORKTREE"
}
trap cleanup_wf EXIT

PREV_RID="$(gh run list --repo "$REPO" --workflow vm-smoke.yml -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
echo ">>> Dispatching..."
dispatched=""
for _ in 1 2 3 4 5 6; do
  gh workflow run vm-smoke.yml --repo "$REPO" --ref "$BRANCH" >/dev/null 2>&1 && { dispatched="yes"; break; }
  sleep 5
done
[ -n "$dispatched" ] || { echo "FAIL: could not dispatch the smoke workflow." >&2; exit 1; }

echo ">>> Waiting for a new run id..."
RID=""; deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  RID="$(gh run list --repo "$REPO" --workflow vm-smoke.yml -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
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
echo "---------------------------------------------"
echo "run $RID: status=$status conclusion=$concl  ran-on=${JOB_RUNNER:-?}"
if [ "$concl" != "success" ]; then
  echo "FAIL: VM smoke run did not succeed." >&2
  echo "      Logs: gh run view $RID --repo $REPO --log-failed ; diagnose with ghrunner-triage." >&2
  exit 1
fi
[ -n "$RUNNER" ] && [ -n "$JOB_RUNNER" ] && [ "$JOB_RUNNER" != "$RUNNER" ] && \
  echo "WARN: ran on '$JOB_RUNNER', expected '$RUNNER'." >&2
echo "PASS: VM self-hosted runner ran the job green ✅"
