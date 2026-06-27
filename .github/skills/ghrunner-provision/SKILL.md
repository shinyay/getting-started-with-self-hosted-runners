---
name: ghrunner-provision
license: MIT
description: >-
  Provision a self-hosted GitHub Actions runner for a target repository and
  verify end-to-end that it works. Use when you want to set up, build, deploy,
  and validate a runner for a repo given as owner/repo or a local clone path: it
  builds the runner image (ACR or local Docker), constructs the runner (ACI,
  local Docker, VM, or AKS+ARC), confirms it registers online, and runs a real
  smoke job to green — then tears down throwaway test resources. Hands diagnosis
  off to ghrunner-triage and registry updates to ghrunner-ops.
  Trigger phrases: set up self-hosted runner, provision runner, build runner for
  repo, verify runner works, runner smoke test, bring up a runner, deploy runner
  for shinyay/<repo>, end-to-end runner.
---

# ghrunner-provision — Bring up & verify a runner for a repo

Given a **target repo** (`owner/repo` or a local clone path), build/choose a
runner image, **construct** a self-hosted runner, and **verify end-to-end**:
the runner registers **online** and a real smoke job goes **green**. Then offer
clean **teardown**.

## When to Use This Skill

- Set up a self-hosted runner for a specific repository and prove it works
- Build the runner image (ACR push or local Docker) as part of bring-up
- Smoke-test a newly provisioned runner (online + a real green job)
- Stand up a throwaway runner to validate a change, then tear it down

## Prerequisites

- `gh` authenticated as the repo owner (e.g. `shinyay`)
- For ACI: `az` reachable to `ghrunner-rg`; `docker` for local builds/runners
- Repo admin on the target (needed to mint a registration token)
- `git` + **SSH push access** to the target repo — `verify-runner.sh` pushes the
  smoke workflow over SSH, so the `workflow` token scope is **not** required
- Repository deletion is **Human-in-the-Loop** — `teardown.sh --show-repo-delete`
  prints the command for you to run; the skill never deletes repos

## Guardrails

- **Never run `az account set`** (`~/.azure` is shared); pass `--subscription`.
- **Never stage/commit/modify the untracked `resume` file.**
- **Throwaway naming**: test runners use a `*-smoke` name and a **non-`latest`**
  image tag; **never** add test runners to `docs/runner-registry.md`, and never
  touch fleet containers `ghrunner-aci-01..11` or the `:latest` image.
- Registration tokens expire ~1h — mint immediately before deploy.
- Writing the smoke workflow to a **real** repo: warn first, use the clear
  filename `runner-smoke.yml`, and remove it afterwards (the verify script does).
- Always offer `teardown.sh` after a test.
- **Irreversible operations are Human-in-the-Loop**: repository deletion (and
  similar destructive actions) are never executed by the skill — emit the exact
  command for the user to run. The skill's token does not need `delete_repo`.

## Flow

### 1 — Resolve the target repo
Accept `owner/repo`, or a local path → `git -C <path> remote get-url origin`
(the scripts do this automatically).

### 2 — Preflight
`gh api user` is the owner; for ACI, `az group show -n ghrunner-rg` succeeds
(else pass `--subscription <id>`).

### 3 — Choose platform & image
ACI / local-docker / VM / ARC, and image via `az acr build` or local
`docker build`. See [references/platforms.md](./references/platforms.md).

### 4 — Construct the runner (ACI is scripted)
```bash
# Build a throwaway image and deploy an ACI runner for the repo:
./.github/skills/ghrunner-provision/scripts/provision-aci.sh OWNER/REPO \
  --name ghrunner-aci-smoke --build-acr smoke-test --ephemeral true
```
For local-docker / VM / ARC, follow [references/platforms.md](./references/platforms.md).

### 5 & 6 — Verify online + a real green job
```bash
./.github/skills/ghrunner-provision/scripts/verify-runner.sh OWNER/REPO \
  --runner ghrunner-aci-smoke --labels azure,linux,x64,aci
```
It waits for the runner to be `online`, writes + dispatches a smoke workflow,
watches the run, and asserts `success` on our runner. Details:
[references/verification.md](./references/verification.md).

### 7 — Report & clean up
On success, report PASS. On failure, hand off to the **ghrunner-triage** skill.
Then tear down throwaway resources:
```bash
./.github/skills/ghrunner-provision/scripts/teardown.sh \
  --repo OWNER/REPO --runner ghrunner-aci-smoke --container ghrunner-aci-smoke \
  --acr-tag smoke-test --smoke-workflow --show-repo-delete --yes
# Repo deletion is Human-in-the-Loop: --show-repo-delete prints the command for YOU to run.
```
For a **permanent** runner instead, record it in `docs/runner-registry.md` via
the **ghrunner-ops** skill.

## Platforms

| Platform | Construct | Verify/Teardown |
|----------|-----------|-----------------|
| **ACI** | `provision-aci.sh` (scripted) | `verify-runner.sh` / `teardown.sh` |
| **local-docker** | `docker run` ([platforms.md](./references/platforms.md)) | same (agnostic) |
| **VM** | Bicep + cloud-init (`docs/06/07`) | same (agnostic) |
| **AKS+ARC** | Helm scale set (`docs/09/16`) | same (agnostic) |

`verify-runner.sh` and `teardown.sh` are **platform-agnostic** — they work for
any runner once it is registered to the repo.

## Troubleshooting

| Symptom | Action |
|---------|--------|
| Runner never goes online | `az container logs -g ghrunner-rg -n <name>`; use **ghrunner-triage** (`AUTH-TOKEN-TTL`, `CFG-LABEL`) |
| Smoke job stuck `queued` | `runs-on` labels don't match the runner labels — align them |
| Smoke job fails on a step | A runner-image gap; **ghrunner-triage** maps the signature → image fix (`ghrunner-ops` A4+A3) |
| RG unreachable | wrong subscription — pass `--subscription <id>` (never `az account set`) |

## References

- [references/platforms.md](./references/platforms.md) — per-platform construct + image build
- [references/verification.md](./references/verification.md) — smoke workflow, online/green checks, teardown
- [scripts/provision-aci.sh](./scripts/provision-aci.sh) · [scripts/verify-runner.sh](./scripts/verify-runner.sh) · [scripts/teardown.sh](./scripts/teardown.sh)
- [`ghrunner-ops`](../ghrunner-ops/SKILL.md) — register/operate a permanent runner · [`ghrunner-triage`](../ghrunner-triage/SKILL.md) — diagnose failures
- `docs/08-aci-setup.md`, `docs/06-07` (VM), `docs/09`/`docs/16` (ARC)
