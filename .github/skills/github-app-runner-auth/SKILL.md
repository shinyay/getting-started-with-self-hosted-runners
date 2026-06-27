---
name: github-app-runner-auth
license: MIT
description: >-
  Authenticate self-hosted runners and ARC to GitHub with a GitHub App instead of
  a PAT. Use when wiring ARC (or private-repo Copilot agent runners) to a GitHub
  App: generate the installation ID from the App ID + private key, mint
  installation and runner-registration tokens, and configure the ARC Kubernetes
  secret (github_app_id / github_app_installation_id / github_app_private_key),
  handling the private key safely. App creation itself is a Human-in-the-Loop web
  UI step. Pairs with arc-ops (arc-up.sh --auth app).
  Trigger phrases: GitHub App auth, ARC GitHub App, installation id, app private
  key, github_app_private_key, app installation token, runner App authentication,
  arc-github-app-secret.
---

# github-app-runner-auth — GitHub App auth for runners / ARC

Authenticate runners and ARC as a **GitHub App** (App ID + installation ID +
private key) rather than a PAT. The App is created in the web UI (Human-in-the-
Loop); this skill automates everything after that and verifies it works.

## When to Use This Skill

- Wire ARC (gha-runner-scale-set) to a GitHub App for a repo or org
- Derive an installation ID, mint installation / registration tokens
- Build the ARC Kubernetes App secret, handling the `.pem` safely
- Diagnose `AUTH-ARC-CREDS` (bad App secret) failures

## Prerequisites

- A **GitHub App you created** (Administration: Read & write; installed on the
  repo/org) — see [references/github-app-setup.md](./references/github-app-setup.md)
- `python3` with PyJWT or `cryptography` (installation-ID JWT); `curl`; `kubectl`
  for the secret; `shred` for key cleanup

## Guardrails

- **Private-key handling**: keep the `.pem` `chmod 600`, **never echo** it,
  **never commit** it (`.gitignore` excludes `*.pem`), and `shred -u` it once it
  lives in the cluster secret (`make-arc-secret.sh --shred`).
- Token output is **opt-in** (`app-token.sh --print`); default reports success
  without printing secrets.
- **Never run `az account set`**; never touch the untracked `resume` file.
- **App creation is Human-in-the-Loop** (web UI); so is repository deletion.

## Flow

### 1 — Create the App (Human-in-the-Loop)
Follow [references/github-app-setup.md](./references/github-app-setup.md):
Administration **Read & write**, webhook off, install on the repo; note the
**App ID** and download the **`.pem`**.

### 2 — Derive the installation ID
```bash
python3 ./.github/skills/github-app-runner-auth/scripts/app-installation-id.py \
  --app-id "$APP_ID" --private-key "$PEM" --repo OWNER/REPO
```

### 3 — Prove the App-auth chain
```bash
./.github/skills/github-app-runner-auth/scripts/app-token.sh \
  --app-id "$APP_ID" --private-key "$PEM" --repo OWNER/REPO
```
Mints an installation token and a runner registration-token (the App can
authorize runner registration).

### 4 — Build the ARC secret & bring up ARC
```bash
# Either create the secret directly:
./.github/skills/github-app-runner-auth/scripts/make-arc-secret.sh \
  --app-id "$APP_ID" --installation-id "$INSTALL_ID" --private-key "$PEM" --shred

# …or let arc-ops do AKS + ARC + the App secret in one step:
./.github/skills/arc-ops/scripts/arc-up.sh OWNER/REPO --provision \
  --scale-set my-set --auth app \
  --github-app-id "$APP_ID" --installation-id "$INSTALL_ID" --private-key-file "$PEM"
```

### 5 — Verify a job green
```bash
./.github/skills/arc-ops/scripts/arc-verify.sh OWNER/REPO --scale-set my-set
```
An ARC runner pod (App-authenticated) runs the job to green. Full mapping:
[references/arc-app-auth.md](./references/arc-app-auth.md).

## The three secret keys

`github_app_id`, `github_app_installation_id`, `github_app_private_key` — these
exact names are what the `gha-runner-scale-set` chart expects.

## Scripts

| Script | Purpose |
|--------|---------|
| [app-installation-id.py](./scripts/app-installation-id.py) | JWT → installation id |
| [app-token.sh](./scripts/app-token.sh) | installation + registration token (chain proof) |
| [make-arc-secret.sh](./scripts/make-arc-secret.sh) | create the ARC App secret (secure key handling) |

## References

- [references/github-app-setup.md](./references/github-app-setup.md) — HITL App creation + key handling
- [references/arc-app-auth.md](./references/arc-app-auth.md) — ARC App secret + verification chain
- [`arc-ops`](../arc-ops/SKILL.md) (`arc-up.sh --auth app`) · [`ghrunner-triage`](../ghrunner-triage/SKILL.md) (`AUTH-ARC-CREDS`) · [`ghrunner-ops`](../ghrunner-ops/SKILL.md) · [`runner-hardening-audit`](../runner-hardening-audit/SKILL.md) (A3 long-lived PAT-in-env; App auth is the fix)
- `docs/09-aks-arc-setup.md` (Part 2), `docs/16-copilot-agent-arc-end-to-end.md` (§3–4), `k8s/arc/values.yaml`
