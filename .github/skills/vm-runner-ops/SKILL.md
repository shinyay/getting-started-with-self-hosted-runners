---
name: vm-runner-ops
license: MIT
description: >-
  Provision, verify, and decommission an Azure VM self-hosted GitHub Actions
  runner using the repo's Bicep + cloud-init. Use when setting up or tearing down
  a VM-based runner (not ACI or Kubernetes): it generates an SSH key, mints a
  registration token, deploys the VM (VNet/NSG/identity/public-IP/NIC), waits for
  cloud-init to register the runner as a systemd service, verifies a real job
  runs green, and decommissions the VM. The VM sibling of ghrunner-provision
  (ACI) and arc-ops (AKS). Workflows target runs-on:[self-hosted, azure, vm].
  Trigger phrases: VM runner, Azure VM self-hosted runner, bicep vm-runner,
  cloud-init runner, provision VM runner, decommission VM, ghrunner-vm.
---

# vm-runner-ops — Azure VM self-hosted runner lifecycle

Provision, verify, and decommission a self-hosted runner on a dedicated Azure VM
via the repo's Bicep + cloud-init. The VM sibling of `ghrunner-provision` (ACI)
and `arc-ops` (AKS).

## When to Use This Skill

- Stand up a VM-based runner for a repo (Bicep + cloud-init)
- Verify the VM runner registered and runs a job green
- Decommission a VM runner (delete the VM / its RG)

## Prerequisites

- `az` (deploy the Bicep), `gh` (mint token / verify); `git` + SSH push for verify
- `ssh-keygen` (to generate an ephemeral VM key) unless you pass `--ssh-key`
- Rights to create a VM + networking in the target subscription

## Guardrails

- **Never run `az account set`** (`~/.azure` is shared); pass `--subscription`.
- **Never stage/commit/modify the untracked `resume` file.**
- **Secret handling**: the registration token is a Bicep `@secure` param passed
  via env/temp and never echoed; the ephemeral SSH private key stays in a temp
  dir and is discarded.
- **RG-scoped deletion**: `vm-down.sh --delete-rg` only deletes the RG you name
  and **refuses `ghrunner-rg`**; default is per-resource VM deletion.
- **Irreversible ops are Human-in-the-Loop**: repository deletion is print-only.
- Tighten `--allowed-ssh-source` to a specific IP/CIDR in production (not `*`).

## Flow

### 1 — Provision the VM
```bash
./.github/skills/vm-runner-ops/scripts/vm-up.sh OWNER/REPO \
  --rg rg-vm-runner --create-rg --vm-name ghrunner-vm-01
```
Generates an SSH key (or `--ssh-key`), mints a token, and deploys
`bicep/vm-runner/main.bicep`. The runner registers via cloud-init a few minutes
later.

### 2 — Verify a job green
```bash
./.github/skills/vm-runner-ops/scripts/vm-verify.sh OWNER/REPO \
  --runner ghrunner-vm-01 --labels azure,linux,x64,vm
```
Waits for the runner online (cloud-init delay), pushes a smoke workflow over
git+SSH, dispatches it, and asserts `success`. Details:
[references/verification.md](./references/verification.md).

### 3 — Operate
Connect (`ssh azureuser@<ip>`), inspect cloud-init / the runner service, patch,
and maintain per [references/vm-operations.md](./references/vm-operations.md).

### 4 — Decommission
```bash
./.github/skills/vm-runner-ops/scripts/vm-down.sh \
  --rg rg-vm-runner --vm-name ghrunner-vm-01 --repo OWNER/REPO \
  --delete-rg --show-repo-delete --yes
```
Deregisters the runner and deletes the dedicated RG (or the VM + named resources
without `--delete-rg`). Repo deletion is Human-in-the-Loop.

## What gets deployed

A self-contained RG: VNet + subnet, NSG, user-assigned identity, Standard public
IP, NIC, and an Ubuntu 22.04 VM whose cloud-init installs and registers the
runner as a **systemd service**. Workflows target `runs-on: [self-hosted, azure,
vm]` (labels default `azure,linux,x64,vm`). See
[references/vm-operations.md](./references/vm-operations.md).

## Troubleshooting

| Symptom | Action |
|---------|--------|
| Runner never comes online | SSH in, `sudo cat /var/log/cloud-init-output.log`; token may have expired — re-run `vm-up.sh` |
| Job stuck `queued` | `runs-on` labels don't match — align them with the VM's labels |
| `actions/checkout@v5` node24 errors | bump `RUNNER_VERSION` in `scripts/vm/cloud-init-runner.yaml` |
| Failure signatures | use the **ghrunner-triage** skill (`INF-OFFLINE`, `INF-DNS`) |

## References

- [references/vm-operations.md](./references/vm-operations.md) — Bicep/cloud-init details + operations catalog
- [references/verification.md](./references/verification.md) — verify a VM runner green
- [scripts/vm-up.sh](./scripts/vm-up.sh) · [scripts/vm-verify.sh](./scripts/vm-verify.sh) · [scripts/vm-down.sh](./scripts/vm-down.sh)
- [`ghrunner-provision`](../ghrunner-provision/SKILL.md) (ACI) · [`arc-ops`](../arc-ops/SKILL.md) (AKS) · [`runner-workflow-onboard`](../runner-workflow-onboard/SKILL.md) · [`ghrunner-triage`](../ghrunner-triage/SKILL.md)
- `bicep/vm-runner/`, `scripts/vm/cloud-init-runner.yaml`, `docs/06-vm-manual-setup.md`, `docs/07-vm-automation.md`
