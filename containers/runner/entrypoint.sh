#!/bin/bash
set -euo pipefail

# -------------------------------------------------------
# GitHub Actions Self-Hosted Runner — Container Entrypoint
# -------------------------------------------------------

RUNNER_DIR="/home/runner/actions-runner"

# Environment variables (with defaults)
GITHUB_URL="${GITHUB_URL:?Error: GITHUB_URL environment variable is required}"
RUNNER_TOKEN="${RUNNER_TOKEN:?Error: RUNNER_TOKEN environment variable is required}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-azure,linux,x64,aci}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
EPHEMERAL="${EPHEMERAL:-true}"

echo "============================================="
echo "  GitHub Actions Self-Hosted Runner"
echo "============================================="
echo "  GitHub URL  : ${GITHUB_URL}"
echo "  Runner Name : ${RUNNER_NAME}"
echo "  Labels      : ${RUNNER_LABELS}"
echo "  Group       : ${RUNNER_GROUP}"
echo "  Ephemeral   : ${EPHEMERAL}"
echo "============================================="

# ---------------------------------------------------
# Graceful shutdown — deregister runner on SIGTERM/SIGINT
# ---------------------------------------------------
cleanup() {
  echo ""
  echo ">>> Caught shutdown signal. Deregistering runner..."

  # Request a remove token from the GitHub API
  REMOVE_TOKEN=""
  if [[ "${GITHUB_URL}" == */repos/* ]] || [[ "${GITHUB_URL}" == *github.com/*/* ]]; then
    # Repo-level runner
    API_URL="${GITHUB_URL}/actions/runners/remove-token"
  else
    # Org-level runner
    API_URL="${GITHUB_URL}/actions/runners/remove-token"
  fi

  # Try to deregister with the original token
  echo ">>> Removing runner configuration..."
  cd "${RUNNER_DIR}"
  ./config.sh remove --token "${RUNNER_TOKEN}" 2>/dev/null || {
    echo ">>> Warning: Could not deregister runner (token may have expired)."
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
