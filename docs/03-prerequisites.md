# Prerequisites

## Azure Account

**Create an Azure account** if you don't have one:

- Free trial: https://azure.microsoft.com/free/ (includes $200 credit)
- Pay-As-You-Go: for ongoing use

**Required RBAC role**: At minimum, `Contributor` on a resource group.

Verify your role:

```bash
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --output table
```

**Subscription selection**:

```bash
# List subscriptions
az account list --output table

# Set active subscription
az account set --subscription "<subscription-name-or-id>"
```

## GitHub Enterprise Cloud

> [!IMPORTANT]
> This tutorial targets **GitHub Enterprise Cloud**. Most setup steps work with GitHub Free/Pro/Team, but features like **runner groups** and **enterprise policies** require Enterprise Cloud.

- **Organization**: You need a GitHub organization (not just a personal account)
- **Required permissions**:

| Action | Required Role |
|--------|--------------|
| Add repo-level runner | Repository Admin |
| Add org-level runner | Organization Owner |
| Manage runner groups | Organization Owner |
| Enterprise policies | Enterprise Owner |

**Create a test repository** (if you don't have one):

```bash
gh repo create my-org/runner-test --public --clone
```

### Enterprise Cloud vs Free/Pro/Team

| Feature | Free/Pro/Team | Enterprise Cloud |
|---------|:------------:|:----------------:|
| Self-hosted runners | ✅ | ✅ |
| Runner groups | ❌ | ✅ |
| Runner group access policies | ❌ | ✅ |
| Enterprise-level runners | ❌ | ✅ |
| Audit log for runners | Limited | ✅ Full |
| Required workflows | ❌ | ✅ |
| IP allow lists | ❌ | ✅ |

## CLI Tools Installation

### Azure CLI

```bash
# Install on Ubuntu/Debian
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Verify
az version

# Login
az login
```

### GitHub CLI

```bash
# Install on Ubuntu/Debian
(type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y

# Verify
gh --version

# Authenticate
gh auth login
```

### kubectl (for AKS section)

```bash
# Install via Azure CLI
az aks install-cli

# Or install directly
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Verify
kubectl version --client
```

### Helm (for ARC section)

```bash
# Install
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version
```

### jq (JSON processing)

```bash
sudo apt-get install -y jq

# Verify
jq --version
```

### curl

```bash
# Usually pre-installed on Ubuntu
sudo apt-get install -y curl

# Verify
curl --version
```

## Verification Checklist

Run this one-command verification script to confirm your environment is ready:

```bash
echo "=== Environment Verification ==="
echo -n "Azure CLI:  " && az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "❌ NOT INSTALLED"
echo -n "GitHub CLI: " && gh --version 2>/dev/null | head -1 || echo "❌ NOT INSTALLED"
echo -n "kubectl:    " && kubectl version --client --short 2>/dev/null || echo "⏭️  Optional (needed for AKS)"
echo -n "Helm:       " && helm version --short 2>/dev/null || echo "⏭️  Optional (needed for ARC)"
echo -n "jq:         " && jq --version 2>/dev/null || echo "❌ NOT INSTALLED"
echo -n "curl:       " && curl --version 2>/dev/null | head -1 || echo "❌ NOT INSTALLED"
echo ""
echo -n "Azure login: " && az account show --query name -o tsv 2>/dev/null || echo "❌ NOT LOGGED IN"
echo -n "GitHub auth: " && gh auth status 2>&1 | head -2 || echo "❌ NOT AUTHENTICATED"
echo "=== Done ==="
```

## Azure Defaults Configuration

```bash
# Set common defaults to avoid repeating in every command
az configure --defaults location=eastus
az configure --defaults group=ghrunner-rg

# Verify defaults
az configure --list-defaults --output table
```

## Resource Naming Conventions

Recommended pattern: `<project>-<environment>-<resource>-<region>`

| Resource | Example Name | Notes |
|----------|-------------|-------|
| Resource Group | `ghrunner-rg` | Short, identifies purpose |
| Virtual Machine | `ghrunner-vm-01` | Numbered for multiple |
| VNet | `ghrunner-vnet` | One per deployment |
| Subnet | `ghrunner-subnet-runners` | Purpose-specific |
| NSG | `ghrunner-nsg` | Attach to subnet |
| Container Registry | `ghrunneracr` | Alphanumeric only |
| AKS Cluster | `ghrunner-aks` | Short and clear |
| Managed Identity | `ghrunner-identity` | For OIDC |

## Estimated Tutorial Costs

> [!TIP]
> All resources in this tutorial can run within the Azure **free trial** $200 credit. Remember to delete resources when done to avoid charges.

| Resource | Config | Est. Cost/Hour | Est. Cost for Tutorial |
|----------|--------|:--------------:|:---------------------:|
| VM (B2s) | 2 vCPU, 4 GB | ~$0.04 | ~$1-2 |
| ACI | 2 vCPU, 4 GB | ~$0.06 | ~$0.50 |
| AKS (2 nodes) | D2s_v5 | ~$0.19 | ~$2-4 |
| ACR (Basic) | 10 GB | ~$0.007 | ~$0.20 |
| **Total** | | | **~$4-7** |

Cleanup command:

```bash
# Delete everything when done
az group delete --name ghrunner-rg --yes --no-wait
```

---

← **Previous:** [Decision Guide](02-decision-guide.md) | **Next:** [Networking & Connectivity](04-networking-connectivity.md) →
