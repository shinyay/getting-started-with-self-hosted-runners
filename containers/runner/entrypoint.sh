#!/bin/bash
set -euo pipefail

# -------------------------------------------------------
# GitHub Actions Self-Hosted Runner — Container Entrypoint
# -------------------------------------------------------

RUNNER_DIR="/home/runner/actions-runner"

# Environment variables (with defaults)
GITHUB_URL="${GITHUB_URL:?Error: GITHUB_URL environment variable is required}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-azure,linux,x64,aci}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
EPHEMERAL="${EPHEMERAL:-true}"

# Token strategy:
#   * Preferred (v0.6.0+): set GH_PAT — entrypoint mints a fresh registration
#     token from the GitHub API on every container start. Survives EPHEMERAL +
#     restart-policy=Always indefinitely (no 1-hour expiry bomb).
#   * Legacy: set RUNNER_TOKEN explicitly (one-shot registration token, 1-h TTL).
#     Kept for backwards compatibility with v0.5.x recreate scripts.
GH_PAT="${GH_PAT:-}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"

if [[ -z "${GH_PAT}" && -z "${RUNNER_TOKEN}" ]]; then
  echo "ERROR: Either GH_PAT (preferred) or RUNNER_TOKEN must be set." >&2
  exit 1
fi

# REPO_PATH = "owner/repo", derived from GITHUB_URL like https://github.com/owner/repo
REPO_PATH="${GITHUB_URL#https://github.com/}"
REPO_PATH="${REPO_PATH%/}"

echo "============================================="
echo "  GitHub Actions Self-Hosted Runner"
echo "============================================="
echo "  GitHub URL  : ${GITHUB_URL}"
echo "  Repo path   : ${REPO_PATH}"
echo "  Runner Name : ${RUNNER_NAME}"
echo "  Labels      : ${RUNNER_LABELS}"
echo "  Group       : ${RUNNER_GROUP}"
echo "  Ephemeral   : ${EPHEMERAL}"
if [[ -n "${GH_PAT}" ]]; then
  echo "  Auth mode   : GH_PAT (self-minting)"
else
  echo "  Auth mode   : RUNNER_TOKEN (legacy one-shot)"
fi
echo "============================================="

# ---------------------------------------------------
# Mint a fresh registration token from GH_PAT (if needed)
# ---------------------------------------------------
if [[ -z "${RUNNER_TOKEN}" ]]; then
  echo ">>> Minting fresh registration token via GitHub API..."
  REG_RESPONSE=$(GH_TOKEN="${GH_PAT}" gh api -X POST \
    "repos/${REPO_PATH}/actions/runners/registration-token" 2>&1) || {
      echo "ERROR: gh api call failed:" >&2
      echo "${REG_RESPONSE}" >&2
      exit 1
    }
  RUNNER_TOKEN=$(echo "${REG_RESPONSE}" | jq -r '.token // empty')
  REG_EXPIRES=$(echo "${REG_RESPONSE}" | jq -r '.expires_at // "?"')
  if [[ -z "${RUNNER_TOKEN}" || "${RUNNER_TOKEN}" == "null" ]]; then
    echo "ERROR: Could not parse token from response:" >&2
    echo "${REG_RESPONSE}" >&2
    exit 1
  fi
  echo ">>> Registration token minted (expires ${REG_EXPIRES})"
fi

# ---------------------------------------------------
# Graceful shutdown — deregister runner on SIGTERM/SIGINT
# ---------------------------------------------------
cleanup() {
  echo ""
  echo ">>> Caught shutdown signal. Deregistering runner..."

  cd "${RUNNER_DIR}"

  # Prefer minting a proper remove-token via GH_PAT (config.sh remove rejects
  # registration tokens). Falls back to RUNNER_TOKEN for legacy compat.
  REMOVE_TOKEN=""
  if [[ -n "${GH_PAT}" ]]; then
    REMOVE_TOKEN=$(GH_TOKEN="${GH_PAT}" gh api -X POST \
      "repos/${REPO_PATH}/actions/runners/remove-token" --jq '.token' 2>/dev/null || echo "")
  fi
  REMOVE_TOKEN="${REMOVE_TOKEN:-${RUNNER_TOKEN}}"

  echo ">>> Removing runner configuration..."
  ./config.sh remove --token "${REMOVE_TOKEN}" 2>/dev/null || {
    echo ">>> Warning: Could not deregister runner."
    echo ">>> You may need to remove the runner manually from GitHub Settings."
  }

  echo ">>> Runner deregistered. Exiting."
}

trap cleanup SIGTERM SIGINT

# ---------------------------------------------------
# Configure the runner
# ---------------------------------------------------
echo ">>> Configuring runner..."

cd "${RUNNER_DIR}"

CONFIG_ARGS=(
  --url "${GITHUB_URL}"
  --token "${RUNNER_TOKEN}"
  --name "${RUNNER_NAME}"
  --labels "${RUNNER_LABELS}"
  --runnergroup "${RUNNER_GROUP}"
  --unattended
  --replace
)

if [[ "${EPHEMERAL}" == "true" ]]; then
  CONFIG_ARGS+=(--ephemeral)
  echo ">>> Ephemeral mode enabled — runner will exit after one job."
fi

./config.sh "${CONFIG_ARGS[@]}"

if [[ $? -ne 0 ]]; then
  echo ">>> ERROR: Runner configuration failed. Exiting."
  exit 1
fi

echo ">>> Runner configured successfully."

# ---------------------------------------------------
# Start the runner
# ---------------------------------------------------
echo ">>> Starting runner..."

./run.sh &
RUNNER_PID=$!

# Wait for runner process — allows trap to fire on signals
wait ${RUNNER_PID}
EXIT_CODE=$?

echo ">>> Runner process exited with code ${EXIT_CODE}."
exit ${EXIT_CODE}
