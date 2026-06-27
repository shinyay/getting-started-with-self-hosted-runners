#!/usr/bin/env bash
#
# setup-oidc.sh — wire a repo's GitHub Actions to Azure via OIDC (passwordless).
#
# Creates an Entra app + service principal, a federated identity credential whose
# subject matches the chosen trigger, an Azure role assignment (least privilege),
# and stores the three identifiers as GitHub Actions secrets.
#
# Usage:
#   setup-oidc.sh <owner/repo | local-clone-path> [options]
# Subject (choose one; default --subject-branch main):
#   --subject-branch BRANCH   subject repo:O/R:ref:refs/heads/BRANCH
#   --subject-env ENV         subject repo:O/R:environment:ENV
#   --subject-pr              subject repo:O/R:pull_request
#   --subject-tag TAG         subject repo:O/R:ref:refs/tags/TAG
# Options:
#   --app-name NAME           Entra app display name (default: <repo>-oidc)
#   --role ROLE               RBAC role (default: Reader)
#   --scope-rg RG             role scope = this resource group (default: ghrunner-rg)
#   --scope-id RESOURCE_ID    role scope = an explicit resource id (overrides --scope-rg)
#   --subscription ID         subscription (default: current; never az account set)
#   --set-secrets true|false  set the 3 gh secrets (default: true)
#   --help
# Outputs CLIENT_ID / TENANT_ID / SUBSCRIPTION_ID for use by verify-oidc.sh.

set -uo pipefail

SUBJECT=""; SUBJECT_DESC=""
APP_NAME=""; ROLE="Reader"; SCOPE_RG="ghrunner-rg"; SCOPE_ID=""
SUBSCRIPTION=""; SET_SECRETS="true"; TARGET=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

set_subject() { [ -z "$SUBJECT" ] || { echo "ERROR: choose only one --subject-*" >&2; exit 2; }; SUBJECT="$1"; SUBJECT_DESC="$2"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --subject-branch) set_subject "ref:refs/heads/$2" "branch:$2"; shift 2;;
    --subject-env) set_subject "environment:$2" "env:$2"; shift 2;;
    --subject-pr) set_subject "pull_request" "pull_request"; shift;;
    --subject-tag) set_subject "ref:refs/tags/$2" "tag:$2"; shift 2;;
    --app-name) APP_NAME="${2:?}"; shift 2;;
    --role) ROLE="${2:?}"; shift 2;;
    --scope-rg) SCOPE_RG="${2:?}"; shift 2;;
    --scope-id) SCOPE_ID="${2:?}"; shift 2;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    --set-secrets) SET_SECRETS="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TARGET" ] && TARGET="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: target <owner/repo | local-path> required" >&2; usage; exit 2; }
for b in az gh; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done
[ -n "$SUBJECT" ] || { SUBJECT="ref:refs/heads/main"; SUBJECT_DESC="branch:main"; }

resolve_repo() {
  local t="$1"
  if git -C "$t" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$t" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
  else printf '%s' "$t"; fi
}
REPO="$(resolve_repo "$TARGET")"
[[ "$REPO" == */* ]] || { echo "ERROR: could not resolve owner/repo from '$TARGET'" >&2; exit 1; }
REPO_SHORT="${REPO#*/}"
[ -n "$APP_NAME" ] || APP_NAME="${REPO_SHORT}-oidc"
FULL_SUBJECT="repo:${REPO}:${SUBJECT}"

AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")
SUB_ID="$(az account show "${AZ_SUB[@]}" --query id -o tsv 2>/dev/null)"
TENANT_ID="$(az account show "${AZ_SUB[@]}" --query tenantId -o tsv 2>/dev/null)"
[ -n "$SUB_ID" ] && [ -n "$TENANT_ID" ] || { echo "ERROR: az not logged in / subscription unreachable" >&2; exit 1; }
[ -n "$SCOPE_ID" ] || SCOPE_ID="/subscriptions/$SUB_ID/resourceGroups/$SCOPE_RG"

echo ">>> Repo: $REPO   Subject: $FULL_SUBJECT"
echo ">>> App: $APP_NAME   Role: $ROLE @ $SCOPE_ID"

# 1. Entra app (idempotent on display name).
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv 2>/dev/null)"
  [ -n "$APP_ID" ] || { echo "ERROR: az ad app create failed" >&2; exit 1; }
  echo ">>> Created app $APP_ID"
else
  echo ">>> Reusing app $APP_ID"
fi

# 2. Service principal (idempotent).
az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null 2>&1
SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)"
[ -n "$SP_OBJECT_ID" ] || { echo "ERROR: could not create/find service principal" >&2; exit 1; }

# 3. Federated credential for the subject (idempotent on name).
FIC_NAME="gh-$(printf '%s' "$SUBJECT_DESC" | tr -c 'a-zA-Z0-9' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
if ! az ad app federated-credential list --id "$APP_ID" --query "[].name" -o tsv 2>/dev/null | grep -qx "$FIC_NAME"; then
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\":\"$FIC_NAME\",
    \"issuer\":\"https://token.actions.githubusercontent.com\",
    \"subject\":\"$FULL_SUBJECT\",
    \"audiences\":[\"api://AzureADTokenExchange\"],
    \"description\":\"GitHub Actions OIDC - $SUBJECT_DESC\"}" >/dev/null 2>&1 \
    && echo ">>> Created FIC $FIC_NAME ($FULL_SUBJECT)" \
    || { echo "ERROR: federated-credential create failed" >&2; exit 1; }
else
  echo ">>> Reusing FIC $FIC_NAME"
fi

# 4. Role assignment (idempotent).
if ! az role assignment list --assignee "$SP_OBJECT_ID" --scope "$SCOPE_ID" --query "[?roleDefinitionName=='$ROLE'] | length(@)" -o tsv 2>/dev/null | grep -qx 1; then
  az role assignment create --assignee "$SP_OBJECT_ID" --role "$ROLE" --scope "$SCOPE_ID" >/dev/null 2>&1 \
    && echo ">>> Assigned $ROLE @ $SCOPE_ID" || echo "WARN: role assignment may have failed (check permissions)"
else
  echo ">>> Role $ROLE already assigned"
fi

# 5. GitHub identifiers (not secrets, but kept out of source).
if [ "$SET_SECRETS" = "true" ]; then
  gh secret set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID" >/dev/null 2>&1
  gh secret set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID" >/dev/null 2>&1
  gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB_ID" >/dev/null 2>&1
  echo ">>> Set GitHub secrets AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID"
fi

echo "---------------------------------------------"
echo "OIDC setup complete for $REPO"
echo "  CLIENT_ID=$APP_ID"
echo "  TENANT_ID=$TENANT_ID"
echo "  SUBSCRIPTION_ID=$SUB_ID"
echo "  SUBJECT=$FULL_SUBJECT"
echo "Next: verify with verify-oidc.sh $REPO --runner <name>"
