---
name: ghrunner-image-release
license: MIT
description: >-
  Build, tag, changelog, and verify the ghrunner self-hosted runner container
  image. Use when releasing a new runner image version: it builds the image in
  ACR with a new vX.Y tag (optionally moving :latest), inserts a row into the
  Image versions table of docs/runner-registry.md (diff preview; you commit),
  verifies the new image works by running a capability-check job to green, and
  recreates affected ACI runners onto the new tag. Covers the :latest snapshot
  rule and semantic version history.
  Trigger phrases: release runner image, build ghrunner image, new image version,
  az acr build, bump runner image, image changelog, recreate runner on new image,
  ghrunner vX.Y, runner image release.
---

# ghrunner-image-release — Release a runner image

Build and publish a new `ghrunner` ACI runner image, record it in the registry,
**verify** it works, and roll it out. This skill produces the image that
`ghrunner-provision` deploys and `ghrunner-ops` records.

## When to Use This Skill

- Ship a new runner image version (add a package/tool, bump the runner version)
- Fix an `IMG-*` failure (a workflow needs a tool the image lacks) by releasing
- Move `:latest` and recreate runners to adopt a new image
- Record the change in the Image versions changelog

## Prerequisites

- `az` (ACR build) reachable to the `shinyayacr202604` registry
- `python3` (registry editor), `git`, `gh`; SSH push for the verify step
- The build context `containers/runner` (Dockerfile + entrypoint.sh)

## Guardrails

- **Never run `az account set`** (`~/.azure` is shared); pass `--subscription`.
- **Never stage/commit/modify the untracked `resume` file.**
- **`:latest` snapshot rule**: moving `:latest` happens only with `--also-latest`;
  existing ACI runners keep their snapshot and must be **recreated** to adopt a
  new image (`recreate-on-image.sh`). Never overwrite a recorded registry version
  with the literal `latest`.
- **Registry edit is a preview**: `release-image.sh` edits the doc and shows the
  diff; **you commit it**. Irreversible ops (repo deletion) are Human-in-the-Loop.
- Throwaway/test builds use a non-release tag and **must not** move `:latest` or
  edit the registry (`--no-doc`).

## Flow

### 1 — Edit the Dockerfile
Add the package / tool / runner version to `containers/runner/Dockerfile`
(mirror the existing `gh` / `az` apt-repo layers).

### 2 — Build, push & changelog
```bash
./.github/skills/ghrunner-image-release/scripts/release-image.sh v0.6.4 \
  --changelog "Adds <tool> so <workflow> works" --also-latest
```
`az acr build`s `ghrunner:v0.6.4` (+`:latest`), inserts the Image versions row,
and prints the registry diff for you to commit. Details:
[references/release-process.md](./references/release-process.md).

### 3 — Verify
Provision a runner on the new tag (ghrunner-provision), then:
```bash
./.github/skills/ghrunner-image-release/scripts/verify-image.sh OWNER/REPO \
  --runner <name> --check "<command needing the new tool>"
```
Asserts a capability-check job goes green. Details:
[references/verification.md](./references/verification.md).

### 4 — Roll out (recreate runners)
```bash
./.github/skills/ghrunner-image-release/scripts/recreate-on-image.sh \
  --runner ghrunner-aci-NN --repo OWNER/REPO \
  --image shinyayacr202604.azurecr.io/ghrunner:v0.6.4 --yes
```
Deregisters + deletes the container and re-creates it on the new image (the
`:latest` snapshot-rule remedy). Update `docs/runner-registry.md` Status if the
runner's recorded version changed.

## Scripts

| Script | Purpose |
|--------|---------|
| [release-image.sh](./scripts/release-image.sh) | build & push a tag (+latest) + registry diff preview |
| [update_registry.py](./scripts/update_registry.py) | pure Image-versions table editor (idempotent) |
| [verify-image.sh](./scripts/verify-image.sh) | capability-check job → green |
| [recreate-on-image.sh](./scripts/recreate-on-image.sh) | recreate a runner on the new tag |

## Troubleshooting

| Symptom | Action |
|---------|--------|
| Capability check red (`command not found`) | the package didn't make it into the image — fix the Dockerfile and re-release; see **ghrunner-triage** IMG-* |
| New runner still lacks the tool | it kept its snapshot — recreate it (`recreate-on-image.sh`) |
| `az acr build` fails | check the build context and the registry name/subscription |
| Registry edit shows nothing | the tag row already exists (idempotent) |

## References

- [references/release-process.md](./references/release-process.md) — process, `:latest` rule, version history
- [references/verification.md](./references/verification.md) — capability-check verification
- [`ghrunner-provision`](../ghrunner-provision/SKILL.md) (deploys the image) · [`ghrunner-ops`](../ghrunner-ops/SKILL.md) (A4 image update / registry) · [`ghrunner-triage`](../ghrunner-triage/SKILL.md) (IMG-* signatures) · [`runner-hardening-audit`](../runner-hardening-audit/SKILL.md) (A1/A5 image freshness & provenance)
- `containers/runner/Dockerfile`, `docs/runner-registry.md` (Image versions), `docs/08-aci-setup.md`
