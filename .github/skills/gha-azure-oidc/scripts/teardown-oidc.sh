#!/usr/bin/env bash
#
# teardown-oidc.sh — remove OIDC wiring created by setup-oidc.sh.
#
# Deletes the federated credential, the role assignment, the Entra app (+ its SP),
# and the three GitHub secrets. Idempotent. Repository deletion is
# Human-in-the-Loop: --show-repo-delete prints the command, never runs it.
#
# Usage:
#   teardown-oidc.sh [options]
# Options:
#   --app-name NAME       Entra app display name to delete (e.g. <repo>-oidc)
#   --app-id APPID        Entra app id (overrides --app-name lookup)
#   --repo owner/repo     repo to remove the 3 AZURE_* secrets from
#   --scope-rg RG         role-assignment scope to clean (default: ghrunner-rg)
#   --scope-id ID         explicit role scope (overrides --scope-rg)
#   --keep-secrets        do not remove the GitHub secrets
#   --show-repo-delete    print the HITL repo-delete command (never runs it)
#   --subscription ID     subscription (never az account set)
#   --yes                 confirm destructive actions
#   --help
# Safety: requires an explicit app name/id; will not guess or bulk-delete apps.

set -uo pipefail

APP_NAME=""; APP_ID=""; REPO=""; SCOPE_RG="ghrunner-rg"; SCOPE_ID=""
KEEP_SECRETS="false"; SHOW_REPO_DELETE="false"; SUBSCRIPTION=""; YES="false"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
need_yes() { [ "$YES" = "true" ] || { echo "Refusing destructive action without --yes: $1" >&2; exit 3; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app-name) APP_NAME="${2:?}"; shift 2;;
    --app-id) APP_ID="${2:?}"; shift 2;;
    --repo) REPO="${2:?}"; shift 2;;
    --scope-rg) SCOPE_RG="${2:?}"; shift 2;;
    --scope-id) SCOPE_ID="${2:?}"; shift 2;;
    --keep-secrets) KEEP_SECRETS="true"; shift;;
    --show-repo-delete) SHOW_REPO_DELETE="true"; shift;;
    --subscription) SUBSCRIPTION="${2:?}"; shift 2;;
    --yes) YES="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "ERROR: 'az' not found" >&2; exit 1; }
AZ_SUB=(); [ -n "$SUBSCRIPTION" ] && AZ_SUB=(--subscription "$SUBSCRIPTION")

# Resolve the app id (explicit id or by display name; never guess broadly).
if [ -z "$APP_ID" ] && [ -n "$APP_NAME" ]; then
  APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null)"
fi

if [ -n "$APP_ID" ]; then
  SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"
  SUB_ID="$(az account show "${AZ_SUB[@]}" --query id -o tsv 2>/dev/null)"
  [ -n "$SCOPE_ID" ] || SCOPE_ID="/subscriptions/$SUB_ID/resourceGroups/$SCOPE_RG"

  # 1. Role assignment(s) for this SP at the scope.
  if [ -n "$SP_OBJECT_ID" ]; then
    if az role assignment list --assignee "$SP_OBJECT_ID" --scope "$SCOPE_ID" --query "length(@)" -o tsv 2>/dev/null | grep -qvx 0; then
      need_yes "delete role assignment(s) for SP $SP_OBJECT_ID @ $SCOPE_ID"
      az role assignment delete --assignee "$SP_OBJECT_ID" --scope "$SCOPE_ID" >/dev/null 2>&1 \
        && echo ">>> Removed role assignment(s) @ $SCOPE_ID" || echo "WARN: could not remove role assignment(s)."
    fi
  fi

  # 2. Delete the app (this also removes its SP and FICs).
  need_yes "delete Entra app $APP_ID (and its SP + federated credentials)"
  az ad app delete --id "$APP_ID" >/dev/null 2>&1 \
    && echo ">>> Deleted Entra app $APP_ID (SP + FICs included)." \
    || echo "WARN: could not delete app $APP_ID."
else
  echo ">>> No app resolved (already gone or no --app-name/--app-id given)."
fi

# 3. Remove GitHub secrets.
if [ "$KEEP_SECRETS" != "true" ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID; do
    gh secret delete "$s" --repo "$REPO" >/dev/null 2>&1 && echo ">>> Deleted secret $s from $REPO" || true
  done
fi

# 4. Repository deletion is Human-in-the-Loop.
if [ "$SHOW_REPO_DELETE" = "true" ] && [ -n "$REPO" ]; then
  echo ">>> Repository deletion is a Human-in-the-Loop step — run it yourself:"
  echo "      web UI : https://github.com/$REPO/settings  (Danger Zone -> Delete this repository)"
  echo "      or CLI : gh repo delete $REPO --yes"
fi

echo ">>> OIDC teardown complete."
