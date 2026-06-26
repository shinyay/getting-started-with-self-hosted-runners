#!/usr/bin/env bash
#
# provision-aci.sh — build/choose a runner image and deploy an ACI runner for a repo.
#
# Usage:
#   provision-aci.sh <owner/repo | local-clone-path> [options]
# Options:
#   --name NAME            container/runner name (default: ghrunner-aci-smoke)
#   --image REF            full image ref (default: <acr>.azurecr.io/ghrunner:latest)
#   --build-acr TAG        az acr build+push ghrunner:TAG first, then use it
#   --labels LABELS        runner labels (default: azure,linux,x64,aci)
#   --ephemeral true|false default: true
#   --restart-policy P     Never|Always|OnFailure (default: Never)
#   --resource-group RG    default: ghrunner-rg
#   --acr NAME             default: shinyayacr202604
#   --subscription ID      az subscription (never runs az account set)
#   --help
# Auth: if GH_PAT is set in the env it is used (self-minting, preferred);
#       otherwise a one-shot registration token is minted via gh.

set -uo pipefail

NAME="ghrunner-aci-smoke"
IMAGE=""
BUILD_ACR_TAG=""
LABELS="azure,linux,x64,aci"
EPHEMERAL="true"
RESTART="Never"
RG="ghrunner-rg"
ACR="shinyayacr202604"
SUBSCRIPTION=""
TARGET=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2;;
    --image) IMAGE="${2:?}"; shift 2;;
    --build-acr) BUILD_ACR_TAG="${2:?}"; shift 2;;
    --labels) LABELS="${2:?}"; shift 2;;
    --ephemeral) EPHEMERAL="${2:?}"; shift 2;;
    --restart-policy) RESTART="${2:?}"; shift 2;;
    --resource-group) RG="${2:?}"; shift 2;;
    --acr) ACR="${2:?}"; shift 2;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TARGET" ] && TARGET="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: target <owner/repo | local-path> required" >&2; usage; exit 2; }
for b in gh az; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done
AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

# Resolve owner/repo from a local clone path, else use as-is.
resolve_repo() {
  local t="$1"
  if git -C "$t" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$t" remote get-url origin 2>/dev/null \
      | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
  else
    printf '%s' "$t"
  fi
}
REPO="$(resolve_repo "$TARGET")"
[[ "$REPO" == */* ]] || { echo "ERROR: could not resolve owner/repo from '$TARGET'" >&2; exit 1; }
echo ">>> Target repo: $REPO"

# Preflight: RG reachable (never az account set).
if ! az group show -n "$RG" "${AZ_SUB[@]}" --query name -o tsv >/dev/null 2>&1; then
  echo "ERROR: resource group '$RG' unreachable. Pass --subscription <id>; never 'az account set'." >&2
  exit 1
fi

# Image: optionally build+push to ACR.
if [ -n "$BUILD_ACR_TAG" ]; then
  echo ">>> Building image ghrunner:$BUILD_ACR_TAG in ACR '$ACR'..."
  az acr build "${AZ_SUB[@]}" -r "$ACR" -t "ghrunner:$BUILD_ACR_TAG" containers/runner || {
    echo "ERROR: az acr build failed" >&2; exit 1; }
  IMAGE="$ACR.azurecr.io/ghrunner:$BUILD_ACR_TAG"
fi
[ -n "$IMAGE" ] || IMAGE="$ACR.azurecr.io/ghrunner:latest"
echo ">>> Image: $IMAGE"

# ACR pull credentials.
ACR_USERNAME="$(az acr credential show -n "$ACR" -g "$RG" "${AZ_SUB[@]}" --query username -o tsv 2>/dev/null)"
ACR_PWD="$(az acr credential show -n "$ACR" -g "$RG" "${AZ_SUB[@]}" --query "passwords[0].value" -o tsv 2>/dev/null)"
[ -n "$ACR_USERNAME" ] && [ -n "$ACR_PWD" ] || { echo "ERROR: could not read ACR credentials" >&2; exit 1; }

# Auth env: prefer GH_PAT (self-minting); else mint a one-shot registration token.
AUTH_KEY=""; AUTH_VAL=""
if [ -n "${GH_PAT:-}" ]; then
  echo ">>> Auth: GH_PAT (self-minting)"
  AUTH_KEY="GH_PAT"; AUTH_VAL="$GH_PAT"
else
  echo ">>> Minting one-shot registration token..."
  REG_TOK="$(gh api "repos/$REPO/actions/runners/registration-token" -X POST --jq '.token' 2>/dev/null)"
  [ -n "$REG_TOK" ] || { echo "ERROR: could not mint registration token (need repo admin)" >&2; exit 1; }
  AUTH_KEY="RUNNER_TOKEN"; AUTH_VAL="$REG_TOK"
fi

echo ">>> Creating ACI container '$NAME' (restart=$RESTART, ephemeral=$EPHEMERAL)..."
az container create -g "$RG" "${AZ_SUB[@]}" --name "$NAME" \
  --image "$IMAGE" \
  --registry-login-server "$ACR.azurecr.io" \
  --registry-username "$ACR_USERNAME" --registry-password "$ACR_PWD" \
  --cpu 2 --memory 4 --os-type Linux --restart-policy "$RESTART" \
  --environment-variables \
    GITHUB_URL="https://github.com/$REPO" RUNNER_NAME="$NAME" \
    RUNNER_LABELS="$LABELS" EPHEMERAL="$EPHEMERAL" \
  --secure-environment-variables "$AUTH_KEY=$AUTH_VAL" \
  --output none || { echo "ERROR: az container create failed" >&2; exit 1; }

echo ">>> Provisioned. Next: verify with"
echo "    ./.github/skills/ghrunner-provision/scripts/verify-runner.sh $REPO --runner $NAME --labels $LABELS"
echo ">>> Logs: az container logs -g $RG -n $NAME"
