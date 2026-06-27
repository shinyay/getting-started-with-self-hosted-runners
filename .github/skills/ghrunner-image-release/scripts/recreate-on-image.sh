#!/usr/bin/env bash
#
# recreate-on-image.sh — recreate an ACI runner on a new image tag.
#
# ACI keeps the deploy-time image snapshot, so a runner does not pick up a new
# `:latest` (or a new version) until it is recreated. This deregisters and
# deletes the named container, then re-creates it on the new image using the
# ghrunner-provision provisioning script.
#
# Usage:
#   recreate-on-image.sh --runner NAME --repo owner/repo --image REF [options]
# Options:
#   --runner NAME           ACI container / runner name (required)
#   --repo owner/repo       repo the runner serves (required)
#   --image REF             full image ref to deploy (required)
#   --ephemeral true|false  default: true
#   --restart-policy P      Never|Always|OnFailure (default: Always)
#   --labels LABELS         runner labels (default: azure,linux,x64,aci)
#   --resource-group RG     default: ghrunner-rg
#   --subscription ID       az subscription (never az account set)
#   --yes                   confirm the delete+recreate
#   --help
# Safety: refuses to act on fleet names without --yes; never az account set.

set -uo pipefail

RUNNER=""; REPO=""; IMAGE=""; EPHEMERAL="true"; RESTART="Always"
LABELS="azure,linux,x64,aci"; RG="ghrunner-rg"; SUBSCRIPTION=""; YES="false"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROVISION="$HERE/../../ghrunner-provision/scripts/provision-aci.sh"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runner) RUNNER="${2:?}"; shift 2;;
    --repo) REPO="${2:?}"; shift 2;;
    --image) IMAGE="${2:?}"; shift 2;;
    --ephemeral) EPHEMERAL="${2:?}"; shift 2;;
    --restart-policy) RESTART="${2:?}"; shift 2;;
    --labels) LABELS="${2:?}"; shift 2;;
    --resource-group) RG="${2:?}"; shift 2;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    --yes) YES="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

[ -n "$RUNNER" ] && [ -n "$REPO" ] && [ -n "$IMAGE" ] || { echo "ERROR: --runner, --repo and --image are required" >&2; usage; exit 2; }
[ "$YES" = "true" ] || { echo "Refusing to delete+recreate '$RUNNER' without --yes" >&2; exit 3; }
for b in az gh; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done
AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

# 1. Deregister the runner from GitHub (best-effort) and delete the container.
RID="$(gh api "repos/$REPO/actions/runners" --jq ".runners[]|select(.name==\"$RUNNER\")|.id" 2>/dev/null || true)"
[ -n "$RID" ] && gh api -X DELETE "repos/$REPO/actions/runners/$RID" >/dev/null 2>&1 && echo ">>> Deregistered runner $RUNNER."
if az container show -g "$RG" -n "$RUNNER" "${AZ_SUB[@]}" --query name -o tsv >/dev/null 2>&1; then
  az container delete -g "$RG" -n "$RUNNER" "${AZ_SUB[@]}" --yes >/dev/null 2>&1 && echo ">>> Deleted old container $RUNNER."
fi

# 2. Recreate on the new image via the provisioning script.
[ -x "$PROVISION" ] || { echo "ERROR: provisioning script not found/executable: $PROVISION" >&2; \
  echo "       Recreate manually with ghrunner-provision provision-aci.sh --image $IMAGE" >&2; exit 1; }
echo ">>> Recreating $RUNNER on $IMAGE (ephemeral=$EPHEMERAL, restart=$RESTART)..."
sub_args=(); [ -n "$SUBSCRIPTION" ] && sub_args=(--subscription "$SUBSCRIPTION")
"$PROVISION" "$REPO" --name "$RUNNER" --image "$IMAGE" --labels "$LABELS" \
  --ephemeral "$EPHEMERAL" --restart-policy "$RESTART" --resource-group "$RG" "${sub_args[@]}" \
  || { echo "ERROR: recreate failed" >&2; exit 1; }
echo ">>> Recreated. Remember to update docs/runner-registry.md if this is a permanent change."
