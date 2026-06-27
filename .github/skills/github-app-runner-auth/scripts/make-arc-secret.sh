#!/usr/bin/env bash
#
# make-arc-secret.sh — create the ARC Kubernetes secret from GitHub App creds.
#
# Creates a secret with the exact keys the gha-runner-scale-set chart expects for
# App auth: github_app_id, github_app_installation_id, github_app_private_key.
# Handles the private key safely (umask 077; optional shred after creation).
#
# Usage:
#   make-arc-secret.sh --app-id ID --installation-id N --private-key PATH [options]
# Options:
#   --secret NAME         secret name (default: arc-github-app-secret)
#   --ns NS               namespace (default: arc-runners)
#   --shred               shred -u the local private key after the secret exists
#   --help
# Requires a working kubeconfig (the target cluster's). Never echoes the key.

set -uo pipefail

umask 077

APP_ID=""; INSTALL_ID=""; PRIVATE_KEY=""; SECRET_NAME="arc-github-app-secret"
NS="arc-runners"; SHRED="false"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app-id) APP_ID="${2:?}"; shift 2;;
    --installation-id) INSTALL_ID="${2:?}"; shift 2;;
    --private-key) PRIVATE_KEY="${2:?}"; shift 2;;
    --secret) SECRET_NAME="${2:?}"; shift 2;;
    --ns) NS="${2:?}"; shift 2;;
    --shred) SHRED="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

[ -n "$APP_ID" ] && [ -n "$INSTALL_ID" ] && [ -n "$PRIVATE_KEY" ] \
  || { echo "ERROR: --app-id, --installation-id and --private-key required" >&2; usage; exit 2; }
[ -f "$PRIVATE_KEY" ] || { echo "ERROR: private key not found: $PRIVATE_KEY" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: 'kubectl' not found" >&2; exit 1; }

echo ">>> Creating secret '$SECRET_NAME' in namespace '$NS'..."
kubectl create namespace "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete secret "$SECRET_NAME" >/dev/null 2>&1 || true
kubectl -n "$NS" create secret generic "$SECRET_NAME" \
  --from-literal=github_app_id="$APP_ID" \
  --from-literal=github_app_installation_id="$INSTALL_ID" \
  --from-file=github_app_private_key="$PRIVATE_KEY" >/dev/null 2>&1 \
  || { echo "ERROR: secret creation failed (is the kubeconfig pointed at the cluster?)" >&2; exit 1; }
echo ">>> Secret '$SECRET_NAME' created (keys: github_app_id, github_app_installation_id, github_app_private_key)."

if [ "$SHRED" = "true" ]; then
  if command -v shred >/dev/null 2>&1; then
    shred -u "$PRIVATE_KEY" && echo ">>> Shredded the local private key ($PRIVATE_KEY)."
  else
    rm -f "$PRIVATE_KEY" && echo ">>> Removed the local private key (shred unavailable)."
  fi
fi

echo ">>> Use this secret as the scale set's githubConfigSecret (App auth)."
