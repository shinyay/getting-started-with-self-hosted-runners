# Release Process — ghrunner runner image

The recurring process for shipping a new `ghrunner` ACI runner image. Scripted by
`release-image.sh` (+ `update_registry.py`), with verification by
`verify-image.sh` and adoption by `recreate-on-image.sh`.

## The five steps

1. **Edit** `containers/runner/Dockerfile` (add the package/tool/runner-version).
   Follow the existing layer style — note the `gh` and `az` installs use the
   official apt repos.
2. **Build & push** a new version tag (and optionally move `:latest`):
   ```bash
   az acr build -r shinyayacr202604 -t ghrunner:v0.6.4 -t ghrunner:latest containers/runner
   ```
   (`release-image.sh v0.6.4 --changelog "…" --also-latest` does this.)
3. **Changelog** — add a row to the **Image versions** table in
   `docs/runner-registry.md` and move the "(current `latest`)" annotation.
   `update_registry.py` does this; `release-image.sh` shows the diff (you commit).
4. **Verify** the image works (`verify-image.sh` runs a capability-check job).
5. **Recreate** any runner that must adopt the new image (`recreate-on-image.sh`).

## The `:latest` snapshot rule (important)

ACI containers keep the **image they were deployed with**. Pushing a new
`:latest` does **not** update running containers, and a container deployed with
the mutable `:latest` tag does not auto-pull on restart. To adopt a new image,
**recreate** the container (`recreate-on-image.sh` or ghrunner-ops A3). When
reconciling the registry ledger, never overwrite a recorded version with the
literal `latest`.

## Versioning

Semantic-ish tags `vMAJOR.MINOR[.PATCH][-suffix]` (e.g. `v0.6.3`,
`v0.6.2-lsb-fix`). Pick the next tag above the current "(current `latest`)" row.
Throwaway/test builds use a clearly non-release tag (e.g. `imgrelease-smoke`) and
**must not** move `:latest` or edit the registry.

## Version history (what each release added)

The Image versions table in `docs/runner-registry.md` is the source of truth.
Recent highlights:

| Tag | Added |
|-----|-------|
| `v0.6.3` | Azure CLI (`az`) — `azure/login@v2` / `az` steps now work |
| `v0.6.2-lsb-fix` | `lsb-release` + `gnupg` for `actions/setup-python@v5` |
| `v0.6.1` | Chromium runtime libs for Playwright |
| `v0.6.0` | GH_PAT self-minting registration tokens |
| `v0.5.0` | GitHub CLI (`gh`) |
| `v0.4.0` | `libyaml-0-2` for `ruby/setup-ruby` |
| `v0.3.0` | runner `2.333.1` (node24) |
| `v0.2.0` | `/opt/hostedtoolcache` owned by `runner` |

Each new release should append a row describing the change and the symptom it
fixes (so `ghrunner-triage` IMG-* signatures map to a fix).

## Build context & image

- Build context: `containers/runner` (Dockerfile + entrypoint.sh).
- ACR: `shinyayacr202604` → `shinyayacr202604.azurecr.io/ghrunner:<tag>`.
- The image is **only** for the ACI/local-docker/VM runners; ARC pods use
  GitHub's `ghcr.io/actions/actions-runner` image instead.
