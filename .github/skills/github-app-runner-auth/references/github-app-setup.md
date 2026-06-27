# GitHub App Setup (Human-in-the-Loop)

ARC and private-repo runners authenticate as a **GitHub App**. The App must be
created in the web UI; everything after that is automated by this skill's scripts.

## Create the App (web UI — you do this)

1. **Personal**: https://github.com/settings/apps → **New GitHub App**
   (**Org**: Org → Settings → Developer settings → GitHub Apps → New).
2. **Name**: e.g. `arc-<repo>` (globally unique). **Homepage URL**: the repo URL.
3. **Webhook**: uncheck **Active** (ARC doesn't use webhooks).
4. **Repository permissions**:

   | Permission | Access |
   |-----------|--------|
   | Administration | **Read and write** |
   | Metadata | Read-only (auto) |

   For an **organization** runner group, also grant **Organization →
   Self-hosted runners: Read and write** (see `docs/09` Part 2).
5. **Where can this App be installed?** → **Only on this account** → **Create**.
6. Note the **App ID** (top of the App settings page).
7. **Generate a private key** → save the downloaded `.pem` to a path you control.
8. **Install App** (left sidebar) → install on your account → **Only select
   repositories** → choose the target repo → **Install**.

## Then hand off to the scripts

```bash
APP_ID=<APP_ID>
PEM=./arc-app.private-key.pem      # the file you downloaded

# 1. Installation id (proves the App + key reach GitHub):
python3 ./.github/skills/github-app-runner-auth/scripts/app-installation-id.py \
  --app-id "$APP_ID" --private-key "$PEM" --repo OWNER/REPO

# 2. Prove the App can authorize runner registration:
./.github/skills/github-app-runner-auth/scripts/app-token.sh \
  --app-id "$APP_ID" --private-key "$PEM" --repo OWNER/REPO
```

## Private key handling (important)

> [!WARNING]
> The `.pem` is a credential. Keep it `chmod 600`, never echo it, never commit
> it (this skill's `.gitignore` excludes `*.pem`). After it lives in the cluster
> secret, **`shred -u`** the local copy (`make-arc-secret.sh --shred` does this).
> Rotate the key from the App settings if it is ever exposed.

## Deriving the installation id without the scripts

The install URL ends with `.../settings/installations/<INSTALLATION_ID>`. Or use
the JWT approach in `docs/16` §3 (the same logic `app-installation-id.py` uses).
