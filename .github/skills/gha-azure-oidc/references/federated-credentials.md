# Federated Identity Credentials — subject-claim cookbook

A **federated identity credential (FIC)** on an Entra app lets a GitHub Actions
job exchange its OIDC token for an Azure access token — **no client secret**.
The FIC's `subject` must **exactly** match the claim GitHub puts in the OIDC
token for that job. A mismatch is the #1 failure (`AADSTS70021: No matching
federated identity record found`).

## Fixed FIC fields

| Field | Value |
|-------|-------|
| `issuer` | `https://token.actions.githubusercontent.com` |
| `audiences` | `["api://AzureADTokenExchange"]` |
| `subject` | depends on the workflow trigger — see below |

## Subject by scenario

| Workflow trigger | `subject` |
|------------------|-----------|
| Push/run on a **branch** | `repo:<owner>/<repo>:ref:refs/heads/<branch>` |
| Any branch (wildcard) | `repo:<owner>/<repo>:ref:refs/heads/*` (needs a wildcard-enabled FIC) |
| A **tag** | `repo:<owner>/<repo>:ref:refs/tags/<tag>` |
| **Pull request** events | `repo:<owner>/<repo>:pull_request` |
| A GitHub **environment** | `repo:<owner>/<repo>:environment:<env>` |

> [!IMPORTANT]
> If the job uses `environment: production`, the OIDC subject becomes
> `…:environment:production` — **not** the branch form. The FIC subject must use
> the environment form, or login fails with `AADSTS70021`.

One FIC = one subject. Add multiple FICs to the same app for multiple triggers
(e.g. one for `main`, one for `pull_request`).

## Create a FIC

```bash
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "gh-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions - main branch"
}'
```

## Roles & least privilege

The app's service principal needs an Azure RBAC role at the scope the workflow
touches. Default to the **least** privilege that lets the job succeed:

| Job does… | Suggested role | Scope |
|-----------|----------------|-------|
| `az account show` / read-only verify | **Reader** | one resource group |
| Deploy to a resource group | **Contributor** | that resource group |
| Push to ACR | **AcrPush** | the ACR resource |
| Read Key Vault secrets | **Key Vault Secrets User** | the vault |

```bash
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
az role assignment create --assignee "$SP_OBJECT_ID" \
  --role "Reader" \
  --scope "/subscriptions/<sub>/resourceGroups/ghrunner-rg"
```

> Prefer a resource-group (or resource) scope over subscription scope. Warn
> before assigning `Contributor`/`Owner` or subscription-wide scope.

## The three GitHub "secrets" are identifiers, not secrets

`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` are **identifiers**.
The actual auth is the OIDC token exchange — nothing secret is stored. Still set
them with `gh secret set` (keeps them out of source) and never echo their values.
