#!/usr/bin/env bash
#
# migrate-workflows.sh — migrate a repo's workflows to self-hosted runners.
#
# Rewrites runs-on (ubuntu-latest / pinned / single-item list / quoted) to the
# target label set and pins missing setup-node/setup-python versions, using the
# bundled transform_workflow.py. PREVIEW by default (prints a diff); --apply
# commits and pushes the migrated workflows over git+SSH.
#
# Usage:
#   migrate-workflows.sh <owner/repo | local-clone-path> [options]
# Options:
#   --apply               commit + push the changes (default: preview/diff only)
#   --labels LABELS       target runs-on labels (default: self-hosted,linux,azure,aci)
#   --node-version V      node-version to pin when missing (default: 20)
#   --python-version V    python-version to pin when missing (default: 3.12)
#   --branch BRANCH       branch to push to (default: repo default branch)
#   --help
# Safety: only edits files under .github/workflows/. git+SSH push needs no
# 'workflow' token scope. Repo/secret never touched.

set -uo pipefail

APPLY="false"; LABELS="self-hosted,linux,azure,aci"; NODE_V="20"; PY_V="3.12"
BRANCH=""; TARGET=""
HERE="$(cd "$(dirname "$0")" && pwd)"
TRANSFORMER="$HERE/transform_workflow.py"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true"; shift;;
    --labels) LABELS="${2:?}"; shift 2;;
    --node-version) NODE_V="${2:?}"; shift 2;;
    --python-version) PY_V="${2:?}"; shift 2;;
    --branch) BRANCH="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TARGET" ] && TARGET="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: target <owner/repo | local-path> required" >&2; usage; exit 2; }
for b in git python3; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done
[ -f "$TRANSFORMER" ] || { echo "ERROR: transformer not found: $TRANSFORMER" >&2; exit 1; }

# Resolve to a working tree. Local git dir -> in place; else clone owner/repo.
LOCAL="false"; CLEANUP=""
if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  WORKTREE="$(cd "$TARGET" && git rev-parse --show-toplevel)"
  REPO="$(git -C "$WORKTREE" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  LOCAL="true"
else
  REPO="$TARGET"
  [[ "$REPO" == */* ]] || { echo "ERROR: '$TARGET' is neither a git dir nor owner/repo" >&2; exit 1; }
  WORKTREE="$(mktemp -d)"; CLEANUP="$WORKTREE"
  echo ">>> Cloning $REPO (SSH)..."
  git clone --depth 1 "git@github.com:$REPO.git" "$WORKTREE" >/dev/null 2>&1 \
    || { echo "ERROR: git clone failed (need SSH access to $REPO)" >&2; rm -rf "$CLEANUP"; exit 1; }
fi
[ -n "$CLEANUP" ] && trap 'rm -rf "$CLEANUP"' EXIT
[ -n "$BRANCH" ] || BRANCH="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)"

WF_DIR="$WORKTREE/.github/workflows"
if [ ! -d "$WF_DIR" ]; then
  echo ">>> No .github/workflows/ in $REPO — nothing to migrate."; exit 0
fi

echo ">>> Repo: $REPO  branch: $BRANCH  labels: [$LABELS]"
echo ">>> Transforming workflows..."
changed_any="false"
shopt -s nullglob
for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  base="$(basename "$f")"
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  # Write bytes exactly (no command substitution, which would strip the trailing
  # newline). The change marker is read from stderr.
  python3 "$TRANSFORMER" --labels "$LABELS" --node-version "$NODE_V" \
    --python-version "$PY_V" --name "$base" < "$f" > "$tmp_out" 2> "$tmp_err"
  marker="$(grep -m1 '^__CHANGED__=' "$tmp_err" | cut -d= -f2)"
  grep -v '^__CHANGED__=' "$tmp_err" | sed 's/^/    /'
  if [ "$marker" = "1" ]; then
    mv "$tmp_out" "$f"
    changed_any="true"
  else
    rm -f "$tmp_out"
  fi
  rm -f "$tmp_err"
done

if [ "$changed_any" != "true" ]; then
  echo ">>> No changes needed (already self-hosted / nothing to map)."
  exit 0
fi

echo ">>> Diff preview:"
git -C "$WORKTREE" --no-pager diff -- .github/workflows | sed 's/^/  /'

if [ "$APPLY" != "true" ]; then
  echo
  echo ">>> PREVIEW ONLY. Re-run with --apply to commit & push these changes."
  [ "$LOCAL" = "true" ] && echo "    (local tree edited in place; revert with: git -C $WORKTREE checkout -- .github/workflows)"
  exit 0
fi

echo ">>> Applying (commit + push over SSH)..."
GID=(-c user.name=runner-workflow-onboard -c user.email=runner-workflow-onboard@users.noreply.github.com)
git -C "$WORKTREE" "${GID[@]}" add .github/workflows >/dev/null 2>&1
git -C "$WORKTREE" "${GID[@]}" commit -m "ci: migrate workflows to self-hosted runners" >/dev/null 2>&1
git -C "$WORKTREE" push origin "HEAD:$BRANCH" >/dev/null 2>&1 \
  && echo ">>> Pushed migrated workflows to $REPO ($BRANCH)." \
  || { echo "ERROR: push failed (need SSH push access)" >&2; exit 1; }
echo ">>> Next: provision a runner (ghrunner-provision) and verify with verify-migration.sh"
