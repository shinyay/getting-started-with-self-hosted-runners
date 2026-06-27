#!/usr/bin/env bash
#
# verify-oidc.sh — prove passwordless GitHub->Azure OIDC login works end-to-end.
#
# Pushes an azure/login@v2 smoke workflow (git+SSH, no 'workflow' scope needed)
# whose trigger matches the FIC subject, dispatches it, watches the run, and
# asserts the Azure login + `az account show` step succeeded on the runner.
#
# Usage:
#   verify-oidc.sh <owner/repo | local-clone-path> [options]
# Options:
#   --runner NAME        expected runner name (assert the job ran on it)
#   --labels LABELS      runs-on labels (default: azure,linux,x64,aci)
#   --environment ENV    add `environment: ENV` to the job (match an env-scoped FIC)
#   --scope-rg RG        resource group the job reads via ARM to prove the role (default: ghrunner-rg)
#   --use-azure-login    verify with azure/login@v2 + `az account show` instead of the
#                        default az-free curl token-exchange (needs `az` on the runner,
#                        i.e. ghrunner image v0.6.3+)
#   --run-timeout S      max seconds to wait for the run (default: 420)
#   --keep               keep the smoke workflow (default: remove it)
#   --help
# Requires the 3 AZURE_* GitHub secrets (set by setup-oidc.sh).

set -uo pipefail

RUNNER=""; LABELS="azure,linux,x64,aci"; ENVIRONMENT=""
RUN_TIMEOUT=420; KEEP="false"; TARGET=""; SCOPE_RG="ghrunner-rg"; USE_AZURE_LOGIN="false"
WF_PATH=".github/workflows/oidc-smoke.yml"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runner) RUNNER="${2:?}"; shift 2;;
    --labels) LABELS="${2:?}"; shift 2;;
    --environment) ENVIRONMENT="${2:?}"; shift 2;;
    --scope-rg) SCOPE_RG="${2:?}"; shift 2;;
    --use-azure-login) USE_AZURE_LOGIN="true"; shift;;
    --run-timeout) RUN_TIMEOUT="${2:?}"; shift 2;;
    --keep) KEEP="true"; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2;;
    *) [ -z "$TARGET" ] && TARGET="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: target <owner/repo | local-path> required" >&2; usage; exit 2; }
for b in gh git; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done

resolve_repo() {
  local t="$1"
  if git -C "$t" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$t" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
  else printf '%s' "$t"; fi
}
REPO="$(resolve_repo "$TARGET")"
[[ "$REPO" == */* ]] || { echo "ERROR: could not resolve owner/repo from '$TARGET'" >&2; exit 1; }
BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
[ -n "$BRANCH" ] || { echo "ERROR: could not read default branch" >&2; exit 1; }
echo ">>> Repo: $REPO (branch: $BRANCH)  runner-labels: $LABELS${ENVIRONMENT:+  env:$ENVIRONMENT}"

RUNS_ON="self-hosted, $(printf '%s' "$LABELS" | sed 's/,/, /g')"
ENV_LINE=""; [ -n "$ENVIRONMENT" ] && ENV_LINE="    environment: $ENVIRONMENT"

WORKTREE="$(mktemp -d)"; trap 'rm -rf "$WORKTREE"' EXIT
GIT_ID=(-c user.name=gha-azure-oidc -c user.email=gha-azure-oidc@users.noreply.github.com)
echo ">>> Cloning (SSH) to place the OIDC smoke workflow..."
git clone --depth 1 "git@github.com:$REPO.git" "$WORKTREE" >/dev/null 2>&1 \
  || { echo "ERROR: git clone failed; need SSH push access" >&2; exit 1; }
mkdir -p "$WORKTREE/.github/workflows"
if [ "$USE_AZURE_LOGIN" = "true" ]; then
# azure/login@v2 + `az account show` — the production pattern. Requires `az` on
# the runner (ghrunner image v0.6.3+).
cat > "$WORKTREE/$WF_PATH" <<YAML
name: OIDC Login Smoke Test
on:
  workflow_dispatch:
permissions:
  id-token: write
  contents: read
jobs:
  oidc-login:
    runs-on: [${RUNS_ON}]
${ENV_LINE}
    steps:
      - name: Azure login via OIDC
        uses: azure/login@v2
        with:
          client-id: \${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: \${{ secrets.AZURE_TENANT_ID }}
          subscription-id: \${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - name: Prove passwordless auth
        run: |
          az account show --output table
          echo "azure/login@v2 passwordless login OK"
YAML
else
# Default: prove OIDC federation END-TO-END without depending on the runner
# image shipping the Azure CLI: (1) get the GitHub OIDC token, (2) exchange it
# at Entra for an ARM access token (proves the FIC subject matches), and (3)
# call ARM REST to read the resource group (proves the role assignment).
# Uses only curl + jq (present in this repo's runner image).
cat > "$WORKTREE/$WF_PATH" <<YAML
name: OIDC Login Smoke Test
on:
  workflow_dispatch:
permissions:
  id-token: write
  contents: read
jobs:
  oidc-login:
    runs-on: [${RUNS_ON}]
${ENV_LINE}
    steps:
      - name: Prove passwordless OIDC federation to Azure
        env:
          AZURE_CLIENT_ID: \${{ secrets.AZURE_CLIENT_ID }}
          AZURE_TENANT_ID: \${{ secrets.AZURE_TENANT_ID }}
          AZURE_SUBSCRIPTION_ID: \${{ secrets.AZURE_SUBSCRIPTION_ID }}
          SCOPE_RG: ${SCOPE_RG}
        run: |
          set -euo pipefail
          echo "::group::Get GitHub OIDC token"
          AUTH_HEADER="Authorization: bearer \${ACTIONS_ID_TOKEN_REQUEST_TOKEN}"
          GH_JWT=\$(curl -sS -H "\$AUTH_HEADER" \\
            "\${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
          echo "::add-mask::\$GH_JWT"
          [ -n "\$GH_JWT" ] && [ "\$GH_JWT" != "null" ] || { echo "no OIDC token (need id-token: write)"; exit 1; }
          echo "subject: \$(echo "\$GH_JWT" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.sub')"
          echo "::endgroup::"

          echo "::group::Exchange for an Azure ARM access token (federation test)"
          RESP=\$(curl -sS -X POST \\
            "https://login.microsoftonline.com/\${AZURE_TENANT_ID}/oauth2/v2.0/token" \\
            -d "client_id=\${AZURE_CLIENT_ID}" \\
            -d "scope=https://management.azure.com/.default" \\
            -d "grant_type=client_credentials" \\
            -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \\
            --data-urlencode "client_assertion=\${GH_JWT}")
          ARM_AT=\$(echo "\$RESP" | jq -r '.access_token // empty')
          echo "::add-mask::\$ARM_AT"
          if [ -z "\$ARM_AT" ]; then
            echo "Federation FAILED:"; echo "\$RESP" | jq -r '.error_description // .' | head -3; exit 1
          fi
          echo "Azure access token obtained — passwordless federation OK."
          echo "::endgroup::"

          echo "::group::Use the token via ARM REST (proves the role assignment)"
          AUTH_SCHEME=Bearer
          CODE=\$(curl -sS -o /tmp/rg.json -w '%{http_code}' \\
            -H "Authorization: \${AUTH_SCHEME} \${ARM_AT}" \\
            "https://management.azure.com/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${SCOPE_RG}?api-version=2021-04-01")
          echo "ARM GET resourceGroup -> HTTP \$CODE"
          [ "\$CODE" = "200" ] && jq -r '.name + " @ " + .location' /tmp/rg.json || \\
            { echo "role not effective yet (HTTP \$CODE)"; cat /tmp/rg.json; exit 1; }
          echo "::endgroup::"
          echo "OIDC passwordless login + role check OK"
YAML
fi

git -C "$WORKTREE" "${GIT_ID[@]}" add "$WF_PATH" >/dev/null 2>&1
git -C "$WORKTREE" "${GIT_ID[@]}" commit -m "ci: add OIDC login smoke test" >/dev/null 2>&1
git -C "$WORKTREE" "${GIT_ID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 \
  || { echo "ERROR: failed to push OIDC smoke workflow over SSH" >&2; exit 1; }
echo ">>> Pushed $WF_PATH"

cleanup_wf() {
  if [ "$KEEP" != "true" ] && [ -f "$WORKTREE/$WF_PATH" ]; then
    git -C "$WORKTREE" "${GIT_ID[@]}" rm "$WF_PATH" >/dev/null 2>&1
    git -C "$WORKTREE" "${GIT_ID[@]}" commit -m "ci: remove OIDC login smoke test" >/dev/null 2>&1
    git -C "$WORKTREE" "${GIT_ID[@]}" push origin "HEAD:$BRANCH" >/dev/null 2>&1 && echo ">>> Removed smoke workflow."
  fi
  rm -rf "$WORKTREE"
}
trap cleanup_wf EXIT

echo ">>> Dispatching..."
# Record the newest existing run id so we can wait for a genuinely NEW one
# (avoids racing onto a stale run from a previous attempt).
PREV_RID="$(gh run list --repo "$REPO" --workflow oidc-smoke.yml --event workflow_dispatch -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
dispatched=""
for _ in 1 2 3 4 5 6; do
  gh workflow run oidc-smoke.yml --repo "$REPO" --ref "$BRANCH" >/dev/null 2>&1 && { dispatched="yes"; break; }
  sleep 5
done
[ -n "$dispatched" ] || { echo "FAIL: could not dispatch the OIDC smoke workflow." >&2; exit 1; }

echo ">>> Waiting for a new run id..."
RID=""; deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  RID="$(gh run list --repo "$REPO" --workflow oidc-smoke.yml --event workflow_dispatch -L1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
  [ -n "$RID" ] && [ "$RID" != "$PREV_RID" ] && break
  RID=""; sleep 3
done
[ -n "$RID" ] || { echo "FAIL: no new run appeared." >&2; exit 1; }
echo ">>> Run id: $RID — watching (timeout ${RUN_TIMEOUT}s)..."

deadline=$(( $(date +%s) + RUN_TIMEOUT )); status=""; concl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  read -r status concl < <(gh run view "$RID" --repo "$REPO" --json status,conclusion --jq '.status+" "+(.conclusion//"")' 2>/dev/null)
  [ "$status" = "completed" ] && break
  sleep 6
done
JOB_RUNNER="$(gh api "repos/$REPO/actions/runs/$RID/jobs" --jq '.jobs[0].runner_name // ""' 2>/dev/null)"
echo "---------------------------------------------"
echo "run $RID: status=$status conclusion=$concl  ran-on=${JOB_RUNNER:-?}"
if [ "$concl" != "success" ]; then
  echo "FAIL: OIDC login job did not succeed." >&2
  echo "      Common cause: FIC subject mismatch (AADSTS70021). See references/troubleshooting.md." >&2
  echo "      View logs: gh run view $RID --repo $REPO --log-failed" >&2
  exit 1
fi
[ -n "$RUNNER" ] && [ -n "$JOB_RUNNER" ] && [ "$JOB_RUNNER" != "$RUNNER" ] && \
  echo "WARN: ran on '$JOB_RUNNER', expected '$RUNNER'." >&2
if [ "$USE_AZURE_LOGIN" = "true" ]; then
  echo "PASS: azure/login@v2 passwordless login succeeded ✅"
else
  echo "PASS: passwordless OIDC federation to Azure succeeded ✅"
fi
