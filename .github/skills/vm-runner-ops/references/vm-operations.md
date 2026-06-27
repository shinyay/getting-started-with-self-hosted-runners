# VM Runner Operations — Azure VM self-hosted runner lifecycle

Provision, operate, and decommission a self-hosted runner on a dedicated Azure
VM, using the repo's Bicep (`bicep/vm-runner/main.bicep`) + cloud-init
(`scripts/vm/cloud-init-runner.yaml`). Scripted by `vm-up.sh` / `vm-verify.sh` /
`vm-down.sh`. Grounded in `docs/06-vm-manual-setup.md` and `docs/07-vm-automation.md`.

## What the Bicep deploys

One self-contained resource group with: a VNet + subnet, an NSG (SSH from
`allowedSshSource`), a user-assigned managed identity, a Standard public IP, a
NIC, and an Ubuntu 22.04 VM. The VM's `customData` is the cloud-init config with
the runner URL / token / name / labels substituted in.

| Bicep param | Default | Notes |
|-------------|---------|-------|
| `vmName` | `ghrunner-vm-01` | also the prefix for `-vnet`/`-nsg`/`-nic`/`-pip`/`-identity` |
| `vmSize` | `Standard_B2s` | 2 vCPU / 4 GiB |
| `runnerLabels` | `azure,linux,x64,vm` | workflows target `runs-on: [self-hosted, …]` |
| `sshPublicKey` | (required, `@secure`) | `vm-up.sh` generates an ephemeral key if none |
| `runnerToken` | (required, `@secure`) | registration token (1h TTL) |
| `allowedSshSource` | (param) | tighten to a specific IP/CIDR in production |

## What cloud-init does (on first boot)

Installs `curl/jq/git/docker`, creates the `runner` user, downloads
actions-runner, runs `installdependencies.sh`, `config.sh` (url/token/name/
labels), and `svc.sh install`+`start` — registering the runner as a **systemd
service**. This happens **after** the deployment returns, so the runner appears
online a few minutes later.

> [!NOTE]
> The cloud-init pins runner **2.321.0** (older than the ACI image's 2.333.1).
> A plain workflow runs fine; actions needing node24 (e.g. `actions/checkout@v5`)
> may require bumping `RUNNER_VERSION` in `scripts/vm/cloud-init-runner.yaml`.

## Operations

### Provision
```bash
./.github/skills/vm-runner-ops/scripts/vm-up.sh OWNER/REPO \
  --rg rg-vm-runner --create-rg --vm-name ghrunner-vm-01
```
Generates an SSH key (or `--ssh-key`), mints a token, and `az deployment group
create`s the Bicep. Then poll `gh api repos/OWNER/REPO/actions/runners` until
the runner is `online`.

### Connect (optional, for debugging)
```bash
ssh azureuser@<public-ip>                      # the Bicep outputs sshCommand
sudo cat /var/log/cloud-init-output.log        # cloud-init / registration log
sudo systemctl status 'actions.runner.*'       # the runner service
```

### Maintain
- Restart the service: `sudo ./svc.sh stop && sudo ./svc.sh start` in the runner
  dir, or `systemctl restart 'actions.runner.*'`.
- OS patches / runner auto-update: see `docs/12-monitoring-maintenance.md`.

### Decommission
```bash
./.github/skills/vm-runner-ops/scripts/vm-down.sh \
  --rg rg-vm-runner --vm-name ghrunner-vm-01 --repo OWNER/REPO --delete-rg --yes
```
Deregisters the runner and deletes the dedicated RG (or the VM + its named
resources without `--delete-rg`). Refuses to delete `ghrunner-rg`.

## Bicep fix note

`main.bicep` previously keyed `userAssignedIdentities` with a module output
(`identity.outputs.identityId`), which Bicep rejects (BCP120 — the key must be
computable at start of deployment). It now uses
`resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', '${vmName}-identity')`
plus `dependsOn: [identity]`. This was required for the VM path to deploy at all.
