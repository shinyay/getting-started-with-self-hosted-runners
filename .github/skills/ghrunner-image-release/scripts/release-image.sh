#!/usr/bin/env bash
#
# release-image.sh — build & publish a ghrunner runner image and update the registry.
#
# Builds the runner image in ACR with a new tag (optionally moving :latest), then
# inserts a row into the Image versions table of docs/runner-registry.md and
# prints a diff PREVIEW (you commit it). Use update_registry.py for the doc edit.
#
# Usage:
#   release-image.sh <tag> --changelog "..." [options]
# Options:
#   --changelog TEXT      Image versions changelog text (required unless --no-doc)
#   --also-latest         also tag/push :latest and mark this tag current latest
#   --acr NAME            ACR name (default: shinyayacr202604)
#   --context DIR         build context (default: containers/runner)
#   --registry PATH       registry doc (default: docs/runner-registry.md)
#   --no-doc              skip the registry doc edit (build/push only)
#   --subscription ID     az subscription (never az account set)
#   --help
# After a release, recreate runners that must adopt the new image
# (recreate-on-image.sh), since ACI keeps the deploy-time image snapshot.

set -uo pipefail

TAG=""; CHANGELOG=""; ALSO_LATEST="false"; ACR="shinyayacr202604"
CONTEXT="containers/runner"; REGISTRY="docs/runner-registry.md"
NO_DOC="false"; SUBSCRIPTION=""
HERE="$(cd "$(dirname "$0")" && pwd)"
UPDATER="$HERE/update_registry.py"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --changelog) CHANGELOG="${2:?}"; shift 2;;
    --also-latest) ALSO_LATEST="true"; shift;;
    --acr) ACR="${2:?}"; shift 2;;
    --context) CONTEXT="${2:?}"; shift 2;;
    --registry) REGISTRY="${2:?}"; shift 2;;
    --no-doc) NO_DOC="true"; shift;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TAG" ] && TAG="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TAG" ] || { echo "ERROR: <tag> required (e.g. v0.6.4)" >&2; usage; exit 2; }
[ "$TAG" = "latest" ] && { echo "ERROR: refusing to release the literal 'latest' tag; use a version tag + --also-latest" >&2; exit 2; }
[ "$NO_DOC" = "true" ] || [ -n "$CHANGELOG" ] || { echo "ERROR: --changelog required (or pass --no-doc)" >&2; exit 2; }
for b in az; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done
[ -d "$CONTEXT" ] || { echo "ERROR: build context not found: $CONTEXT" >&2; exit 1; }
AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

# 1. Build & push.
TAGS=(-t "ghrunner:$TAG")
[ "$ALSO_LATEST" = "true" ] && TAGS+=(-t "ghrunner:latest")
echo ">>> Building ghrunner:$TAG${ALSO_LATEST:+ (+latest)} in ACR '$ACR' from '$CONTEXT'..."
az acr build "${AZ_SUB[@]}" -r "$ACR" "${TAGS[@]}" "$CONTEXT" \
  || { echo "ERROR: az acr build failed" >&2; exit 1; }
echo ">>> Published $ACR.azurecr.io/ghrunner:$TAG"
[ "$ALSO_LATEST" = "true" ] && echo ">>> Also moved :latest to this build."

# 2. Update the registry doc (preview; you commit).
if [ "$NO_DOC" != "true" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "WARN: python3 missing; skipping registry edit" >&2; exit 0; }
  [ -f "$REGISTRY" ] || { echo "WARN: registry not found: $REGISTRY; skipping" >&2; exit 0; }
  args=(--registry "$REGISTRY" --tag "$TAG" --changelog "$CHANGELOG")
  [ "$ALSO_LATEST" = "true" ] && args+=(--also-latest)
  python3 "$UPDATER" "${args[@]}" 2> >(grep -v '^__CHANGED__=' >&2) || { echo "ERROR: registry edit failed" >&2; exit 1; }
  echo ">>> Registry diff preview:"
  git --no-pager diff -- "$REGISTRY" | sed 's/^/  /'
  echo
  echo ">>> PREVIEW: review and commit docs/runner-registry.md yourself, e.g.:"
  echo "      git add $REGISTRY && git commit -m \"docs(runner-registry): image $TAG\""
fi

echo ">>> Next: verify (verify-image.sh) and recreate affected runners (recreate-on-image.sh)."
echo ">>> Note: existing ACI runners keep their snapshot; recreate to adopt $TAG."
