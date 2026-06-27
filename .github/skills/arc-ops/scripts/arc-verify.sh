#!/usr/bin/env bash
#
# arc-verify.sh — prove an ARC scale set runs a job green on a runner pod.
#
# Pushes a smoke workflow (runs-on: <scale-set>, workflow_dispatch) over git+SSH,
# dispatches it, watches for a NEW run, and asserts conclusion=success. Also
# reports that ARC created an ephemeral runner pod (proves autoscaling).
#
# Usage:
#   arc-verify.sh <owner/repo | local-clone-path> --scale-set NAME [options]
# Options:
#   --scale-set NAME      runner scale set name = runs-on label — required
#   --ns-runners NS       runners namespace (default: arc-runners)
#   --run-timeout S       max seconds to wait for the run (default: 600)
#   --keep                keep the smoke workflow (default: remove it)
#   --help

set -uo pipefail

SCALE_SET=""; NS_RUN="arc-runners"; RUN_TIMEOUT=600; KEEP="false"; TARGET=""
WF_PATH=".github/workflows/arc-smoke.yml"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scale-set) SCALE_SET="${2:?}"; shift 2;;
    --ns-runners) NS_RUN="${2:?}"; shift 2;;
    --run-timeout) RUN_TIMEOUT="${2:?}"; shift 2;;
    --keep) KEEP="true"; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TARGET" ] && TARGET="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: <owner/repo | local-path> required" >&2; usage; exit 2; }
[ -n "$SCALE_SET" ] || { echo "ERROR: --scale-set NAME required" >&2; usage; exit 2; }
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
echo ">>> Repo: $REPO  scale-set/runs-on: $SCALE_SET  branch: $BRANCH"

# Push the smoke workflow over git+SSH (no 'workflow' token scope needed).
WORKTREE="$(mktemp -d)"; trap 'rm -rf "$WORKTREE"' EXIT
GID=(-c user.name=arc-ops -c user.email=arc-ops@users.noreply.github.com)
git clone --depth 1 "git@github.com:$REPO.git" "$WORKTREE" >/dev/null 2>&1 \
  || { echo "ERROR: git clone failed; need SSH push access" >&2; exit 1; }
mkdir -p "$WORKTREE/.github/workflows"
cat > "$WORKTREE/$WF_PATH" <<YAML
name: ARC Smoke Test
on:
  workflow_dispatch:
jobs:
  arc:
    runs-on: ${SCALE_SET}
    steps:
      - name: Prove ARC runner
        run: |
          echo "Running on ARC pod: \$(hostname)"
          echo "ARC scale set smoke OK"
YAML
git -C "$WORKTREE" "${GID[@]}" add "$WF_PATH" >/dev/null 2>&1
git -C "$WORKTREE" "${GID[@]}" commit -m "ci: add ARC smoke test" >/dev/null 2>&1
git -C "$WORKTREE" "${GID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 \
  || { echo "ERROR: failed to push smoke workflow" >&2; exit 1; }
echo ">>> Pushed $WF_PATH"

cleanup_wf() {
  if [ "$KEEP" != "true" ] && [ -f "$WORKTREE/$WF_PATH" ]; then
    git -C "$WORKTREE" "${GID[@]}" rm "$WF_PATH" >/dev/null 2>&1
    git -C "$WORKTREE" "${GID[@]}" commit -m "ci: remove ARC smoke test" >/dev/null 2>&1
    git -C "$WORKTREE" "${GID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 && echo ">>> Removed smoke workflow."
  fi
  rm -rf "$WORKTREE"
}
trap cleanup_wf EXIT

PREV_RID="$(gh run list --repo "$REPO" --workflow arc-smoke.yml -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
echo ">>> Dispatching..."
dispatched=""
for _ in 1 2 3 4 5 6; do
  gh workflow run arc-smoke.yml --repo "$REPO" --ref "$BRANCH" >/dev/null 2>&1 && { dispatched="yes"; break; }
  sleep 5
done
[ -n "$dispatched" ] || { echo "FAIL: could not dispatch the smoke workflow." >&2; exit 1; }

echo ">>> Waiting for a new run id..."
RID=""; deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  RID="$(gh run list --repo "$REPO" --workflow arc-smoke.yml -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
  [ -n "$RID" ] && [ "$RID" != "$PREV_RID" ] && break
  RID=""; sleep 3
done
[ -n "$RID" ] || { echo "FAIL: no new run appeared." >&2; exit 1; }
echo ">>> Run id: $RID — watching (timeout ${RUN_TIMEOUT}s)..."

# In the background, capture evidence that ARC scaled up a runner pod.
pod_seen=""
deadline=$(( $(date +%s) + RUN_TIMEOUT )); status=""; concl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -z "$pod_seen" ] && command -v kubectl >/dev/null 2>&1; then
    p="$(kubectl -n "$NS_RUN" get pods 2>/dev/null | grep -E "$SCALE_SET" | grep -vi listener | head -1)"
    [ -n "$p" ] && { pod_seen="$p"; echo ">>> ARC runner pod observed: $(echo "$p" | awk '{print $1" "$3}')"; }
  fi
  read -r status concl < <(gh run view "$RID" --repo "$REPO" --json status,conclusion --jq '.status+" "+(.conclusion//"")' 2>/dev/null)
  [ "$status" = "completed" ] && break
  sleep 6
done

echo "---------------------------------------------"
echo "run $RID: status=$status conclusion=$concl"
[ -n "$pod_seen" ] && echo "arc runner pod: $(echo "$pod_seen" | awk '{print $1}')" || echo "arc runner pod: (not captured; job may have completed quickly)"
if [ "$concl" != "success" ]; then
  echo "FAIL: ARC smoke run did not succeed." >&2
  echo "      Check: kubectl -n $NS_RUN get pods; and the ghrunner-triage skill (AUTH-ARC-CREDS, INF-AKS-STOPPED)." >&2
  echo "      Logs: gh run view $RID --repo $REPO --log-failed" >&2
  exit 1
fi
echo "PASS: ARC scale set ran the job green on a runner pod ✅"
