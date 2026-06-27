# OIDC Troubleshooting — GitHub → Azure passwordless login

Symptoms appear in the `azure/login@v2` step. Most are **subject mismatches** or
**missing permissions**.

## AADSTS / login errors

| Error | Cause | Fix |
|-------|-------|-----|
| `AADSTS70021: No matching federated identity record found` | FIC `subject` ≠ the job's OIDC subject | Make the FIC subject match the trigger exactly (branch vs `environment:` vs `pull_request`) — see [federated-credentials.md](./federated-credentials.md) |
| `Error: Unable to get ACTIONS_ID_TOKEN_REQUEST_URL` | Workflow lacks OIDC permission | Add `permissions:` with `id-token: write` (job or top level) |
| `AADSTS700016: Application not found in the directory` | Wrong `AZURE_TENANT_ID` | Set the tenant that owns the app |
| `AADSTS700024: Client assertion is not within its valid time range` | Clock skew on a self-hosted runner | Sync time (NTP) on the runner host |
| `AADSTS50020: User/identity does not exist in tenant` | App created in the wrong tenant | Recreate the app in the correct Entra tenant |
| `AuthorizationFailed` on the first `az` command after login | SP has no role at that scope | Add the right role assignment (least privilege) |
| `azure/login` fails: `Unable to locate executable file: az` | The **runner image has no Azure CLI** (this repo's `ghrunner` image does not ship `az`) | Add `az` to the runner image (image bump → `ghrunner-ops` A4+A3), or use the az-free OIDC token-exchange pattern that `verify-oidc.sh` uses (curl + jq) |

## Debug the OIDC token claims (in a workflow step)

```yaml
      - name: Debug OIDC claims
        run: |
          AUTH_HEADER="Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}"
          OIDC_JWT=$(curl -sS -H "$AUTH_HEADER" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
          # Decode the JWT payload to read the `sub` (subject) claim:
          echo "$OIDC_JWT" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud, repository, ref, environment}'
```

Compare the printed `sub` to the FIC `subject` — they must be identical.

## Self-hosted runner specifics

OIDC behaves **identically** on self-hosted and GitHub-hosted runners — no
runner-side config. The runner only needs outbound 443 to
`token.actions.githubusercontent.com` and `login.microsoftonline.com`. If a
proxy is used, do **not** put those hosts in `NO_PROXY` incorrectly. Runner-side
failures (offline, labels) → use the **ghrunner-triage** skill.

## MCAPS / Microsoft-tenant note

OIDC works in MCAPS tenants **because it uses no client secret**. The tenant's
Conditional-Access policy that blocks service-principal *client-credential*
tokens (`AADSTS53003`) does **not** affect OIDC federation. Do **not** "fix" a
subject mismatch by adding a client secret — it won't help and may be blocked;
correct the FIC subject instead.
