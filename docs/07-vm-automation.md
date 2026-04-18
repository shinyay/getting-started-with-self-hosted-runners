# VM Automation — cloud-init and Bicep

In the [previous guide](06-vm-manual-setup.md) we set up a self-hosted runner on an Azure VM step-by-step. That works for learning, but manual provisioning doesn't scale. This guide automates the entire process two ways:

1. **cloud-init** — a single YAML file that configures the VM on first boot.
2. **Bicep** — Infrastructure as Code that provisions _all_ Azure resources plus the runner in one command.

---

## Part 1: Automated Setup with cloud-init

### What Is cloud-init?

[cloud-init](https://cloud-init.io/) is the industry-standard tool for early-stage VM initialization. Azure (and most clouds) inject the cloud-init payload into the VM at creation time, and the `cloud-init` agent that ships with Ubuntu images processes it on first boot.

A cloud-init file can install packages, create users, write files, and run arbitrary commands — everything we did manually, encoded as declarative YAML.

### Walking Through `cloud-init-runner.yaml`

The file lives at [`scripts/vm/cloud-init-runner.yaml`](../scripts/vm/cloud-init-runner.yaml).

#### Package Installation

```yaml
package_update: true
package_upgrade: false

packages:
  - curl
  - jq
  - git
  - docker.io
  - build-essential
```

`package_update: true` runs `apt-get update` so the package index is fresh. We skip `package_upgrade` to keep boot time short, then install the packages the runner needs — Docker for container-based jobs and `build-essential` for native compilation.

#### User and Group Setup

```yaml
runcmd:
  - usermod -aG docker azureuser
  - useradd -m -s /bin/bash runner
  - usermod -aG docker runner
```

We add the default `azureuser` to the `docker` group (handy for SSH debugging) and create a dedicated `runner` user that the Actions service will run under.

#### Runner Download and Installation

```yaml
  - |
    RUNNER_VERSION="2.321.0"
    RUNNER_ARCH="x64"
    RUNNER_DIR="/home/runner/actions-runner"
    mkdir -p ${RUNNER_DIR}
    cd ${RUNNER_DIR}
    curl -o "actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" -L \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    tar xzf "./actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    rm -f "./actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    ./bin/installdependencies.sh
    chown -R runner:runner ${RUNNER_DIR}
```

The runner tarball is downloaded from GitHub, extracted, and dependencies are installed — the same steps from the manual guide, but fully scripted.

#### Configuration and Service Registration

```yaml
    su - runner -c "cd ${RUNNER_DIR} && ./config.sh \
      --url __GITHUB_URL__ \
      --token __RUNNER_TOKEN__ \
      --name __RUNNER_NAME__ \
      --labels __RUNNER_LABELS__ \
      --runnergroup Default \
      --work _work \
      --unattended \
      --replace"
    cd ${RUNNER_DIR}
    ./svc.sh install runner
    ./svc.sh start
```

`config.sh` registers the runner with GitHub using placeholder tokens that get replaced before deployment. The `--unattended` flag skips interactive prompts and `--replace` lets us re-provision onto the same name. Finally the runner is installed as a systemd service so it survives reboots.

### Deploying with Azure CLI

First, replace the placeholders with real values using `sed`, then pass the file to `az vm create`:

```bash
# Get a registration token (org-level example)
RUNNER_TOKEN=$(gh api -X POST \
  /orgs/YOUR-ORG/actions/runners/registration-token \
  --jq '.token')

# Prepare the cloud-init file with actual values
sed -e 's|__GITHUB_URL__|https://github.com/YOUR-ORG/YOUR-REPO|' \
    -e "s|__RUNNER_TOKEN__|${RUNNER_TOKEN}|" \
    -e 's|__RUNNER_NAME__|ghrunner-vm-auto|' \
    -e 's|__RUNNER_LABELS__|azure,linux,x64,vm|' \
    scripts/vm/cloud-init-runner.yaml > /tmp/cloud-init-configured.yaml

# Create the VM with cloud-init
az vm create \
  --resource-group ghrunner-rg \
  --name ghrunner-vm-auto \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --custom-data /tmp/cloud-init-configured.yaml \
  --tags purpose=github-runner provisioning=cloud-init
```

### Verification

```bash
# SSH into the VM
ssh azureuser@<PUBLIC_IP>

# Check cloud-init finished successfully
cloud-init status --wait          # should print "status: done"
cat /var/log/cloud-init-output.log | tail -30

# Check the runner service
sudo systemctl status actions.runner.*.service
```

> **⚠️ Security Warning:** The cloud-init file contains the runner registration token in plain text. For production deployments, fetch the token at boot time from **Azure Key Vault** using the VM's managed identity instead of baking it into the custom data.

---

## Part 2: Infrastructure as Code with Bicep

### Why Bicep?

Azure Resource Manager (ARM) templates are powerful but verbose JSON. **Bicep** is a domain-specific language that compiles to ARM JSON but offers:

- Concise, readable syntax
- First-class module system
- Type safety and editor tooling (VS Code extension)
- Automatic dependency resolution between resources

The Bicep files in this repo provision _everything_ — networking, identity, and the VM with a pre-configured runner — in a single deployment.

### File Overview

```
bicep/
├── modules/
│   ├── network.bicep      # VNet + Subnet + NSG
│   └── identity.bicep     # Managed identity + role assignment
└── vm-runner/
    ├── main.bicep          # Main template — orchestrates modules + VM
    └── main.parameters.json
```

### Network Module (`modules/network.bicep`)

This module creates the networking layer:

| Resource | Purpose |
|---|---|
| **NSG** | Firewall rules — allow SSH inbound (from your IP), allow HTTPS outbound (GitHub API), deny everything else inbound |
| **VNet** | Isolated virtual network (`10.0.0.0/16` default) |
| **Subnet** | Runner subnet (`10.0.1.0/24`) associated with the NSG |

Key NSG rules:

```
AllowSSH (1000)        — Inbound TCP/22 from allowedSshSource
AllowHTTPSOutbound (1000) — Outbound TCP/443 to any
DenyAllInbound (4096)  — Inbound * deny (catch-all)
```

### Identity Module (`modules/identity.bicep`)

Creates a **user-assigned managed identity** and grants it the Contributor role on the resource group. This lets the VM authenticate to Azure services without storing credentials.

### Main Template (`vm-runner/main.bicep`)

The main template ties everything together:

1. **Loads cloud-init** — `loadTextContent()` reads `cloud-init-runner.yaml` at compile time.
2. **Replaces placeholders** — Bicep's `replace()` function substitutes `__GITHUB_URL__`, `__RUNNER_TOKEN__`, etc.
3. **References modules** — networking and identity are deployed as sub-deployments.
4. **Creates the VM** — Ubuntu 22.04 LTS with SSH key auth, the managed identity, and the configured cloud-init as custom data.

The `customData` property accepts a base64-encoded string:

```bicep
customData: base64(cloudInitConfigured)
```

### Deploying with Bicep

1. **Edit the parameters file** — update `bicep/vm-runner/main.parameters.json` with your values:

   ```json
   {
     "sshPublicKey": { "value": "ssh-rsa AAAA..." },
     "githubUrl": { "value": "https://github.com/YOUR-ORG/YOUR-REPO" },
     "runnerToken": { "value": "<token from gh api>" },
     "runnerName": { "value": "ghrunner-vm-01" },
     "runnerLabels": { "value": "azure,linux,x64,vm" },
     "allowedSshSource": { "value": "203.0.113.50/32" }
   }
   ```

2. **Create the resource group and deploy:**

   ```bash
   # Create resource group
   az group create --name ghrunner-rg --location eastus

   # Deploy everything
   az deployment group create \
     --resource-group ghrunner-rg \
     --template-file bicep/vm-runner/main.bicep \
     --parameters bicep/vm-runner/main.parameters.json
   ```

3. **Get the outputs:**

   ```bash
   az deployment group show \
     --resource-group ghrunner-rg \
     --name main \
     --query properties.outputs
   ```

### Verification

```bash
# SSH into the VM using the output sshCommand
ssh azureuser@<PUBLIC_IP>

# Verify cloud-init completed
cloud-init status --wait

# Check runner service
sudo systemctl status actions.runner.*.service

# Verify runner appears in GitHub
gh api /repos/YOUR-ORG/YOUR-REPO/actions/runners --jq '.runners[] | {name, status}'
```

### Production Tips

| Concern | Recommendation |
|---|---|
| **High availability** | Deploy multiple VMs across availability zones |
| **Secrets management** | Store runner tokens in Azure Key Vault; fetch at boot via managed identity |
| **SSH hardening** | Replace public IP + SSH with **Azure Bastion** for jump-box-free access |
| **Scaling** | Use Virtual Machine Scale Sets (VMSS) to scale runners with demand |
| **Monitoring** | Enable Azure Monitor agent for log collection and alerting |
| **Updates** | Reimage VMs on a schedule rather than patching in place |

---

## Part 3: Cleanup

Delete the entire resource group to remove all resources at once:

```bash
az group delete --name ghrunner-rg --yes --no-wait
```

The `--no-wait` flag returns immediately while deletion happens in the background.

---

← **Previous:** [VM Manual Setup](06-vm-manual-setup.md) | **Next:** [ACI Setup](08-aci-setup.md) →
