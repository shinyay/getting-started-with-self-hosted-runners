---
name: gha-azure-oidc
license: MIT
description: >-
  Set up and verify passwordless GitHub Actions to Azure authentication using
  OIDC / workload identity federation. Use when a repo's workflows need to log in
  to Azure without storing a client secret: it creates the Entra app + service
  principal, adds a federated identity credential whose subject matches the
  workflow trigger, assigns an Azure role, stores AZURE_CLIENT_ID/TENANT_ID/
  SUBSCRIPTION_ID as GitHub secrets, adds an azure/login@v2 workflow, and proves
  it works by running a real job to green. Covers branch/environment/PR/tag
  subjects and AADSTS troubleshooting.
  Trigger phrases: OIDC, workload identity federation, azure/login, passwordless
  Azure, federated credential, AZURE_CLIENT_ID, id-token write, AADSTS70021,
  GitHub Azure auth, configure OIDC.
---

# gha-azure-oidc — Passwordless GitHub → Azure (OIDC)

Wire a repository's GitHub Actions to authenticate to Azure via **OIDC**
(workload identity federation) — no client secret — and **verify end-to-end**
that a real job logs in. Then add the `azure/login@v2` workflow.

## When to Use This Skill

- A workflow needs `azure/login` / `az` access to Azure without a stored secret
- Set up the Entra app + federated credential + role + GitHub secrets for a repo
- Diagnose `AADSTS70021` / "no matching federated identity record" failures
- Migrate a workflow from a service-principal secret to OIDC

## Prerequisites

- `az` logged in with rights to create an Entra app + role assignment (Owner or
  User Access Administrator at the target scope)
- `gh` authenticated as the repo owner; `git` + **SSH push** to the repo
  (workflows are added over SSH — no `workflow` token scope needed)
- A runner to execute the verify job (use the **ghrunner-provision** skill for a
  self-hosted ACI runner, or a GitHub-hosted runner — OIDC behaves identically)

## Guardrails

- **Never run `az account set`** (`~/.azure` is shared); pass `--subscription`.
- **Never stage/commit/modify the untracked `resume` file.**
- **Identifiers, not secrets**: `AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID` are
  identifiers (the auth is the OIDC exchange), but still set via `gh secret set`
  and never echoed.
- **Least privilege**: default role `Reader`, scoped to one resource group; warn
  before `Contributor`/`Owner` or subscription-wide scope.
- **Irreversible ops are Human-in-the-Loop**: repository deletion is print-only
  (`teardown-oidc.sh --show-repo-delete`).
- **Subject exactness**: the FIC `subject` must match the trigger exactly — see
  [references/federated-credentials.md](./references/federated-credentials.md).

## Flow

### 1 — Resolve repo & choose the subject
`owner/repo` or a local clone path. Pick the subject scenario that matches how
the workflow runs: branch / environment / pull_request / tag.

### 2 — Set up OIDC
```bash
./.github/skills/gha-azure-oidc/scripts/setup-oidc.sh OWNER/REPO \
  --subject-branch main --role Reader --scope-rg ghrunner-rg
```
Creates the Entra app + SP, the federated credential
(`repo:OWNER/REPO:ref:refs/heads/main`), the role assignment, and the 3 GitHub
secrets.

### 3 — Verify end-to-end (real job)
```bash
./.github/skills/gha-azure-oidc/scripts/verify-oidc.sh OWNER/REPO \
  --runner <runner-name> --labels azure,linux,x64,aci
```
Pushes an `azure/login@v2` + `az account show` workflow over git+SSH, dispatches
it, and asserts the run is `success`. For an environment-scoped subject, add
`--environment <env>`.

### 4 — Add the production workflow
Keep the verified pattern (or `.github/workflows/deploy-azure-oidc.yml` in this
repo as a template): `permissions: id-token: write` + `azure/login@v2` with the
three secrets, on a trigger that matches the FIC subject.

> [!IMPORTANT]
> `azure/login@v2` (and any `az` step) requires the **Azure CLI on the runner**.
> This repo's `ghrunner` image does **not** ship `az`, so `azure/login` fails
> with `Unable to locate executable file: az`. Either add `az` to the runner
> image (image bump via the `ghrunner-ops` skill, then recreate the runner), or
> use the **az-free token-exchange** pattern that `verify-oidc.sh` uses
> (GitHub OIDC token → Entra token exchange → ARM REST with `curl`+`jq`).

### 5 — Report / teardown
On failure → [references/troubleshooting.md](./references/troubleshooting.md)
(AADSTS70021 = subject mismatch). To remove test wiring:
```bash
./.github/skills/gha-azure-oidc/scripts/teardown-oidc.sh \
  --app-name REPO-oidc --repo OWNER/REPO --scope-rg ghrunner-rg \
  --show-repo-delete --yes
```

## Subject quick reference

| Trigger | `subject` |
|---------|-----------|
| branch | `repo:O/R:ref:refs/heads/<branch>` |
| environment | `repo:O/R:environment:<env>` |
| pull_request | `repo:O/R:pull_request` |
| tag | `repo:O/R:ref:refs/tags/<tag>` |

Full cookbook + role scoping: [references/federated-credentials.md](./references/federated-credentials.md).

## Troubleshooting (top failures)

| Symptom | Fix |
|---------|-----|
| `AADSTS70021: No matching federated identity record found` | FIC subject ≠ trigger — align them ([federated-credentials.md](./references/federated-credentials.md)) |
| `Unable to get ACTIONS_ID_TOKEN_REQUEST_URL` | add `permissions: id-token: write` |
| `AADSTS700016` | wrong `AZURE_TENANT_ID` |
| `AuthorizationFailed` after login | SP lacks a role at that scope |
| Runner offline / job queued | runner-side — use the **ghrunner-triage** skill |

Full table + token-claim debug + MCAPS note: [references/troubleshooting.md](./references/troubleshooting.md).

## References

- [references/federated-credentials.md](./references/federated-credentials.md) — subject cookbook + role scoping
- [references/troubleshooting.md](./references/troubleshooting.md) — AADSTS* + OIDC token-claim debug
- [scripts/setup-oidc.sh](./scripts/setup-oidc.sh) · [scripts/verify-oidc.sh](./scripts/verify-oidc.sh) · [scripts/teardown-oidc.sh](./scripts/teardown-oidc.sh)
- [`ghrunner-provision`](../ghrunner-provision/SKILL.md) — supply a runner for the verify job · [`ghrunner-triage`](../ghrunner-triage/SKILL.md) — runner-side failures
- `docs/10-oidc-workload-identity.md`, `.github/workflows/deploy-azure-oidc.yml`, `bicep/modules/identity.bicep`
