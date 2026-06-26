# Platforms Reference — constructing a runner

How to build the runner image and construct a runner on each platform. The repo
the runner serves is given as `owner/repo` or a **local clone path** (resolve
with `git -C <path> remote get-url origin`).

## Runner env contract (from `containers/runner/entrypoint.sh`)

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `GITHUB_URL` | ✅ | — | `https://github.com/<owner>/<repo>` |
| `RUNNER_NAME` | ❌ | hostname | display name |
| `RUNNER_LABELS` | ❌ | `azure,linux,x64,aci` | comma-separated |
| `EPHEMERAL` | ❌ | `true` | exit after one job |
| `GH_PAT` | one of | — | **preferred**; self-mints a fresh registration token each start |
| `RUNNER_TOKEN` | one of | — | legacy one-shot registration token (~1h TTL) |

GitHub also auto-attaches `self-hosted`, `Linux`, `X64`. Target workflows with
`runs-on: [self-hosted, linux, <your-labels>]`.

## Image build — both modes

```bash
# A) ACR build & push (for ACI/cloud). Use a NON-latest tag for tests.
az acr build -r shinyayacr202604 -t ghrunner:<tag> containers/runner

# B) Local docker build (for local-docker; not pushed).
docker build -t ghrunner:<tag> containers/runner
```

> [!IMPORTANT]
> ACI keeps the deploy-time image snapshot. Never overwrite `:latest` during a
> test — use a throwaway tag (e.g. `smoke-test`).

---

## ACI (scripted, primary)

Use [../scripts/provision-aci.sh](../scripts/provision-aci.sh): it resolves the
repo, builds (or reuses) the image, reads ACR pull credentials, mints a token
(or uses `GH_PAT`), and `az container create`s the runner with the right
environment. Example:

```bash
# optional: export GH_PAT for the self-minting image; else a token is minted
GH_PAT="$GH_PAT" ./.github/skills/ghrunner-provision/scripts/provision-aci.sh \
  <owner>/<repo> --name ghrunner-aci-12 --build-acr v0.6.3 --ephemeral true
```

The script injects `GITHUB_URL`, `RUNNER_NAME`, `RUNNER_LABELS`, `EPHEMERAL` and
the auth secret as ACI environment variables. Never run `az account set`; add
`--subscription <id>` if the RG is unreachable.

## local-docker (scripted-friendly)

Good for a quick local bring-up against a clone (the `-e RUNNER_TOKEN`
passthrough keeps the value out of the command line):

```bash
docker build -t ghrunner:local containers/runner
read -r RUNNER_TOKEN < <(gh api repos/<owner>/<repo>/actions/runners/registration-token -X POST --jq '.token')
export RUNNER_TOKEN
docker run -d --name ghrunner-local \
  -e GITHUB_URL=https://github.com/<owner>/<repo> \
  -e RUNNER_NAME=ghrunner-local \
  -e RUNNER_LABELS=self-hosted,linux,x64,local \
  -e EPHEMERAL=true \
  -e RUNNER_TOKEN \
  ghrunner:local
```

## VM (Bicep + cloud-init)

```bash
az deployment group create -g <rg> \
  --template-file bicep/vm-runner/main.bicep \
  --parameters bicep/vm-runner/main.parameters.json
```

`scripts/vm/cloud-init-runner.yaml` installs and registers the runner on boot.
See `docs/06-vm-manual-setup.md` and `docs/07-vm-automation.md`.

## AKS + ARC (Helm scale set)

Install the ARC controller + a runner scale set (`k8s/arc/values.yaml`,
`runner-scale-set.yaml`, `network-policy.yaml`); requires a GitHub App and a
running AKS cluster. See `docs/09-aks-arc-setup.md` and
`docs/16-copilot-agent-arc-end-to-end.md`.

---

After construction, **verify** with
[verification.md](./verification.md) / [../scripts/verify-runner.sh](../scripts/verify-runner.sh).
On failure, hand off to the **ghrunner-triage** skill.
