#!/usr/bin/env bash
#
# teardown.sh — idempotent cleanup of provisioned/test runner resources.
#
# Usage:
#   teardown.sh [options]            # only acts on the flags you pass
# Options:
#   --repo owner/repo        repo to deregister the runner from / clean
#   --runner NAME            runner name to deregister from --repo
#   --container NAME         ACI container to delete (ghrunner-rg)
#   --acr-tag TAG            delete ACR image ghrunner:TAG
#   --local-container NAME   docker container to remove (-f)
#   --local-image REF        docker image to remove (rmi)
#   --smoke-workflow         delete .github/workflows/runner-smoke.yml from --repo
#   --delete-repo            DELETE the --repo entirely (needs --yes)
#   --resource-group RG      default: ghrunner-rg
#   --acr NAME               default: shinyayacr202604
#   --subscription ID        az subscription (never az account set)
#   --yes                    confirm destructive actions
#   --help
# Safety: refuses to delete fleet containers ghrunner-aci-01..11 or :latest.

set -uo pipefail

REPO=""; RUNNER=""; CONTAINER=""; ACR_TAG=""
LOCAL_CONTAINER=""; LOCAL_IMAGE=""; SMOKE_WF="false"; DELETE_REPO="false"
RG="ghrunner-rg"; ACR="shinyayacr202604"; SUBSCRIPTION=""; YES="false"
WF_PATH=".github/workflows/runner-smoke.yml"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2;;
    --runner) RUNNER="${2:?}"; shift 2;;
    --container) CONTAINER="${2:?}"; shift 2;;
    --acr-tag) ACR_TAG="${2:?}"; shift 2;;
    --local-container) LOCAL_CONTAINER="${2:?}"; shift 2;;
    --local-image) LOCAL_IMAGE="${2:?}"; shift 2;;
    --smoke-workflow) SMOKE_WF="true"; shift;;
    --delete-repo) DELETE_REPO="true"; shift;;
    --resource-group) RG="${2:?}"; shift 2;;
    --acr) ACR="${2:?}"; shift 2;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    --yes) YES="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")
need_yes() { [ "$YES" = "true" ] || { echo "Refusing destructive action without --yes: $1" >&2; exit 3; }; }

# Safety guard: never touch production fleet or :latest.
if [[ "$CONTAINER" =~ ^ghrunner-aci-(0[1-9]|1[01])$ ]]; then
  echo "ERROR: '$CONTAINER' is a production fleet container — refusing." >&2; exit 3
fi
if [ "$ACR_TAG" = "latest" ]; then
  echo "ERROR: refusing to delete the ':latest' image tag." >&2; exit 3
fi

# 1. Deregister the runner from GitHub.
if [ -n "$REPO" ] && [ -n "$RUNNER" ]; then
  command -v gh >/dev/null 2>&1 || { echo "WARN: gh missing; skip deregister" >&2; }
  RID="$(gh api "repos/$REPO/actions/runners" --jq ".runners[]|select(.name==\"$RUNNER\")|.id" 2>/dev/null || true)"
  if [ -n "$RID" ]; then
    need_yes "deregister runner $RUNNER (id $RID) from $REPO"
    gh api -X DELETE "repos/$REPO/actions/runners/$RID" >/dev/null 2>&1 \
      && echo ">>> Deregistered runner $RUNNER." || echo "WARN: could not deregister $RUNNER."
  else
    echo ">>> Runner $RUNNER not registered (already gone)."
  fi
fi

# 2. Delete the ACI container.
if [ -n "$CONTAINER" ]; then
  if az container show -g "$RG" -n "$CONTAINER" "${AZ_SUB[@]}" --query name -o tsv >/dev/null 2>&1; then
    need_yes "delete ACI container $CONTAINER"
    az container delete -g "$RG" -n "$CONTAINER" "${AZ_SUB[@]}" --yes >/dev/null 2>&1 \
      && echo ">>> Deleted ACI container $CONTAINER." || echo "WARN: could not delete $CONTAINER."
  else
    echo ">>> ACI container $CONTAINER not found (already gone)."
  fi
fi

# 3. Delete the throwaway ACR tag.
if [ -n "$ACR_TAG" ]; then
  need_yes "delete ACR image ghrunner:$ACR_TAG"
  az acr repository delete -n "$ACR" "${AZ_SUB[@]}" --image "ghrunner:$ACR_TAG" --yes >/dev/null 2>&1 \
    && echo ">>> Deleted ACR image ghrunner:$ACR_TAG." || echo ">>> ACR tag $ACR_TAG not found / already gone."
fi

# 4. Local docker cleanup.
if [ -n "$LOCAL_CONTAINER" ] && command -v docker >/dev/null 2>&1; then
  docker rm -f "$LOCAL_CONTAINER" >/dev/null 2>&1 && echo ">>> Removed docker container $LOCAL_CONTAINER." || true
fi
if [ -n "$LOCAL_IMAGE" ] && command -v docker >/dev/null 2>&1; then
  docker rmi "$LOCAL_IMAGE" >/dev/null 2>&1 && echo ">>> Removed docker image $LOCAL_IMAGE." || true
fi

# 5. Remove the smoke workflow via git+SSH (no 'workflow' scope needed).
if [ "$SMOKE_WF" = "true" ] && [ -n "$REPO" ] && [ "$DELETE_REPO" != "true" ] && command -v git >/dev/null 2>&1; then
  WT="$(mktemp -d)"
  GID=(-c user.name=ghrunner-provision -c user.email=ghrunner-provision@users.noreply.github.com)
  if git clone --depth 1 "git@github.com:$REPO.git" "$WT" >/dev/null 2>&1 && [ -f "$WT/$WF_PATH" ]; then
    git -C "$WT" "${GID[@]}" rm "$WF_PATH" >/dev/null 2>&1
    git -C "$WT" "${GID[@]}" commit -m "ci: remove smoke test" >/dev/null 2>&1
    git -C "$WT" push origin HEAD >/dev/null 2>&1 && echo ">>> Removed smoke workflow from $REPO."
  fi
  rm -rf "$WT"
fi

# 6. Delete the throwaway repo.
if [ "$DELETE_REPO" = "true" ] && [ -n "$REPO" ]; then
  need_yes "DELETE repository $REPO"
  gh repo delete "$REPO" --yes >/dev/null 2>&1 && echo ">>> Deleted repo $REPO." || echo "WARN: could not delete $REPO (needs delete_repo scope)."
fi

echo ">>> Teardown complete."
