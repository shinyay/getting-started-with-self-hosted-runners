# ARC with GitHub App authentication

ARC's `gha-runner-scale-set` reads GitHub credentials from a Kubernetes secret.
With App auth the secret has **exactly** these three keys:

| Secret key | Value |
|------------|-------|
| `github_app_id` | the App ID |
| `github_app_installation_id` | the installation ID (derive with `app-installation-id.py`) |
| `github_app_private_key` | the `.pem` contents (`--from-file`) |

## Create the secret

```bash
./.github/skills/github-app-runner-auth/scripts/make-arc-secret.sh \
  --app-id "$APP_ID" --installation-id "$INSTALL_ID" --private-key "$PEM" \
  --secret arc-github-app-secret --ns arc-runners --shred
```
(`umask 077`; `--shred` removes the local `.pem` once the secret exists.)

## Bring up ARC with App auth

The `arc-ops` skill's `arc-up.sh` supports `--auth app` and creates this secret
for you:

```bash
./.github/skills/arc-ops/scripts/arc-up.sh OWNER/REPO \
  --rg rg-arc --aks aks-arc --provision --scale-set my-set \
  --auth app --github-app-id "$APP_ID" --installation-id "$INSTALL_ID" \
  --private-key-file "$PEM"
```

Then verify a job green on an ARC runner pod:

```bash
./.github/skills/arc-ops/scripts/arc-verify.sh OWNER/REPO --scale-set my-set
```

## Verification chain

App auth is proven end to end by:

1. **installation id** — `app-installation-id.py` (JWT → `/app/installations`).
2. **installation token** — `app-token.sh` (`POST /app/installations/{id}/access_tokens`).
3. **registration token** — `app-token.sh --repo …` (the App authorizes runner
   registration — what ARC needs).
4. **a green job** — `arc-verify.sh` (an ARC pod, App-authenticated, runs a job).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `/app/installations` 401/403 | wrong App ID or key mismatch | re-check App ID; regenerate the key |
| registration-token request fails | App lacks **Administration: R/W** | add the permission, then re-install |
| listener `CrashLoopBackOff` | secret keys wrong / not installed on repo | fix the secret keys; install the App on the repo (`AUTH-ARC-CREDS` in ghrunner-triage) |
| pods Pending / cluster Stopped | infra | see `arc-ops` troubleshooting (`INF-AKS-STOPPED`) |
