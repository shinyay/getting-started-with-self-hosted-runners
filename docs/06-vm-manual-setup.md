# VM Manual Setup — Step by Step

This is the core hands-on guide. By the end, you'll have a working self-hosted runner on an Azure VM processing GitHub Actions jobs. Covers both Azure Portal and Azure CLI approaches.

> [!NOTE]
> This guide covers **manual setup**. For automated provisioning with cloud-init and Bicep, see [VM Automation](07-vm-automation.md).

## Part 1: Create Azure VM via Portal (Beginner)

### Step 1: Create Resource Group

1. Go to [Azure Portal](https://portal.azure.com)
2. Search "Resource groups" → Click **Create**
3. Subscription: Select your subscription
4. Resource group name: `ghrunner-rg`
5. Region: `East US` (or your preferred region)
6. Click **Review + create** → **Create**

### Step 2: Create Virtual Machine

1. Search "Virtual machines" → Click **Create** → **Azure virtual machine**
2. **Basics tab**:
   - Resource group: `ghrunner-rg`
   - Virtual machine name: `ghrunner-vm-01`
   - Region: `(US) East US`
   - Availability options: No infrastructure redundancy required
   - Security type: Standard
   - Image: **Ubuntu Server 22.04 LTS - x64 Gen2**
   - VM architecture: x64
   - Size: **Standard_B2s** (2 vCPU, 4 GiB RAM) — Click "See all sizes" to find it
     > [!TIP]
     > B2s is sufficient for light CI/CD. For builds with Docker or large dependencies, consider B2ms (8 GB) or D2s_v5.
   - Authentication type: **SSH public key**
   - Username: `azureuser`
   - SSH public key source: Generate new key pair (or use existing)
   - Key pair name: `ghrunner-vm-01_key`
   - Public inbound ports: Allow selected ports
   - Select inbound ports: **SSH (22)**

3. **Disks tab**:
   - OS disk type: **Standard SSD** (sufficient for tutorial)
   - Delete with VM: ✅ Check

4. **Networking tab**:
   - Virtual network: **(new) ghrunner-vnet** (auto-created)
   - Subnet: **(new) default (10.0.0.0/24)** (auto-created)
   - Public IP: **(new) ghrunner-vm-01-ip**
   - NIC network security group: **Basic**
   - Public inbound ports: Allow selected ports
   - Select inbound ports: SSH (22)
   - Delete public IP and NIC when VM is deleted: ✅ Check

5. **Management tab**:
   - Enable auto-shutdown: ✅ **Yes** (saves costs during tutorial)
   - Shutdown time: 19:00 (your local time)
   - Time zone: Your timezone

6. Click **Review + create** → **Create**
7. When prompted, **Download private key** (save the .pem file)

### Step 3: Connect via SSH

```bash
# Set permissions on the key file
chmod 400 ~/Downloads/ghrunner-vm-01_key.pem

# Connect
ssh -i ~/Downloads/ghrunner-vm-01_key.pem azureuser@<PUBLIC_IP>

# Find the public IP in the Azure Portal → VM → Overview → Public IP address
```

## Part 2: Create Azure VM via CLI (Intermediate)

```bash
# 1. Create resource group
az group create \
  --name ghrunner-rg \
  --location eastus

# 2. Create VM
az vm create \
  --resource-group ghrunner-rg \
  --name ghrunner-vm-01 \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --nsg-rule SSH \
  --os-disk-size-gb 30 \
  --tags purpose=github-runner environment=tutorial

# 3. Enable auto-shutdown (saves cost)
az vm auto-shutdown \
  --resource-group ghrunner-rg \
  --name ghrunner-vm-01 \
  --time 1900

# 4. Get the public IP
VM_IP=$(az vm show -d \
  --resource-group ghrunner-rg \
  --name ghrunner-vm-01 \
  --query publicIps -o tsv)
echo "VM IP: $VM_IP"

# 5. SSH into the VM
ssh azureuser@$VM_IP
```

> [!TIP]
> The `--generate-ssh-keys` flag creates keys at `~/.ssh/id_rsa` if they don't exist, or uses existing keys.

## Part 3: Install and Configure the Runner

Now you're SSH'd into the VM. Follow these steps:

### Step 1: Update System Packages

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### Step 2: Install Required Dependencies

```bash
sudo apt-get install -y \
  curl \
  jq \
  git \
  build-essential \
  libssl-dev \
  libffi-dev \
  python3 \
  python3-pip
```

### Step 3: (Optional) Install Docker

Many CI workflows need Docker. Install it now:

```bash
# Install Docker
curl -fsSL https://get.docker.com | sudo sh

# Add azureuser to docker group (to run without sudo)
sudo usermod -aG docker azureuser

# Verify (may need to log out and back in)
newgrp docker
docker run hello-world
```

### Step 4: Create a Dedicated Runner User

> [!IMPORTANT]
> Run the runner as a non-root, dedicated user for security.

```bash
# Create runner user
sudo useradd -m -s /bin/bash runner

# Add to docker group (if Docker is installed)
sudo usermod -aG docker runner

# Switch to runner user
sudo su - runner
```

### Step 5: Download the Runner Application

```bash
# Create runner directory
mkdir ~/actions-runner && cd ~/actions-runner

# Check the latest version at: https://github.com/actions/runner/releases
# Download (replace version as needed)
RUNNER_VERSION="2.321.0"
curl -o "actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" -L \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

# Extract
tar xzf "./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

# Clean up the archive
rm -f "./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
```

### Step 6: Install Runner Dependencies

```bash
# Exit runner user temporarily for sudo access
exit

# Install dependencies (as azureuser with sudo)
sudo /home/runner/actions-runner/bin/installdependencies.sh

# Switch back to runner user
sudo su - runner
cd ~/actions-runner
```

### Step 7: Get a Registration Token

Choose one method:

**Method A: GitHub UI**

1. Go to your repository → **Settings** → **Actions** → **Runners**
2. Click **New self-hosted runner**
3. Select **Linux** → Copy the token from the `./config.sh` command

**Method B: GitHub CLI** (from your local machine, not the VM)

```bash
# Repository-level
RUNNER_TOKEN=$(gh api repos/OWNER/REPO/actions/runners/registration-token \
  -X POST --jq '.token')
echo $RUNNER_TOKEN
```

**Method C: Organization-level** (Enterprise Cloud)

```bash
RUNNER_TOKEN=$(gh api orgs/YOUR-ORG/actions/runners/registration-token \
  -X POST --jq '.token')
echo $RUNNER_TOKEN
```

### Step 8: Configure the Runner

```bash
# On the VM, as the runner user:
./config.sh \
  --url https://github.com/OWNER/REPO \
  --token <RUNNER_TOKEN> \
  --name "ghrunner-vm-01" \
  --labels "azure,linux,x64,vm" \
  --runnergroup "Default" \
  --work "_work" \
  --replace
```

Explanation of options:

| Option | Description |
|--------|-------------|
| `--url` | Repository or organization URL |
| `--token` | Registration token (expires in 1 hour) |
| `--name` | Display name for the runner |
| `--labels` | Custom labels (comma-separated) |
| `--runnergroup` | Runner group (Enterprise Cloud only) |
| `--work` | Working directory for job execution |
| `--replace` | Replace existing runner with same name |

For organization-level registration:

```bash
./config.sh \
  --url https://github.com/YOUR-ORG \
  --token <RUNNER_TOKEN> \
  --name "ghrunner-vm-01" \
  --labels "azure,linux,x64,vm" \
  --runnergroup "Default" \
  --work "_work"
```

### Step 9: Test the Runner Interactively

```bash
./run.sh
```

You should see:

```
√ Connected to GitHub

Current runner version: '2.321.0'
Listening for Jobs
```

Press `Ctrl+C` to stop (we'll set up as a service next).

### Step 10: Install as a Systemd Service

```bash
# Exit runner user
exit

# Install the service (as azureuser with sudo)
cd /home/runner/actions-runner
sudo ./svc.sh install runner

# Start the service
sudo ./svc.sh start

# Check status
sudo ./svc.sh status
```

The service will:
- Start automatically on boot
- Restart on failure
- Run as the `runner` user

Verify the service:

```bash
# Check systemd service
sudo systemctl status actions.runner.*.service

# View logs
sudo journalctl -u actions.runner.*.service -f
```

### Step 11: Verify in GitHub

1. Go to your repository → **Settings** → **Actions** → **Runners**
2. You should see `ghrunner-vm-01` with status **Idle** (green dot)
3. Labels should show: `self-hosted`, `Linux`, `X64`, `azure`, `vm`

## Part 4: Test with a Workflow

Create a test workflow to verify everything works.

On your **local machine** (not the VM):

```bash
# In your repository
mkdir -p .github/workflows
```

Create `.github/workflows/test-self-hosted.yml`:

```yaml
name: Test Self-Hosted Runner

on:
  workflow_dispatch:  # Manual trigger

jobs:
  test:
    runs-on: [self-hosted, linux, azure]
    steps:
      - name: System Information
        run: |
          echo "🖥️  Hostname: $(hostname)"
          echo "🐧 OS: $(lsb_release -ds)"
          echo "🏃 Runner: ${RUNNER_NAME}"
          echo "📂 Workspace: ${GITHUB_WORKSPACE}"
          echo "💾 Disk Space:"
          df -h /
          echo "🧠 Memory:"
          free -h
          echo "🔧 Docker:"
          docker --version 2>/dev/null || echo "Docker not installed"

      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Run a Script
        run: |
          echo "✅ Self-hosted runner is working!"
          echo "Repository: ${{ github.repository }}"
          echo "Ref: ${{ github.ref }}"
```

Trigger the workflow:

```bash
# Push the workflow file
git add .github/workflows/test-self-hosted.yml
git commit -m "Add self-hosted runner test workflow"
git push

# Trigger manually
gh workflow run "Test Self-Hosted Runner"

# Watch the run
gh run watch
```

## Part 5: Installing Additional Tools

Common tools you might want on your runner:

### Node.js (via nvm)

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
source ~/.bashrc
nvm install --lts
node --version
```

### Java (OpenJDK)

```bash
sudo apt-get install -y openjdk-17-jdk
java --version
```

### .NET SDK

```bash
wget https://dot.net/v1/dotnet-install.sh
chmod +x dotnet-install.sh
./dotnet-install.sh --channel 8.0
echo 'export PATH="$HOME/.dotnet:$PATH"' >> ~/.bashrc
```

### Go

```bash
GO_VERSION="1.22.5"
wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
echo 'export PATH="/usr/local/go/bin:$PATH"' >> ~/.bashrc
```

> [!TIP]
> Alternatively, use GitHub Actions' `setup-*` actions (e.g., `actions/setup-node`, `actions/setup-java`) in your workflows instead of pre-installing tools. This gives version flexibility per workflow.

## Cleanup

When you're done with this tutorial section:

```bash
# Delete all resources
az group delete --name ghrunner-rg --yes --no-wait

# Or just stop the VM to save costs
az vm deallocate --resource-group ghrunner-rg --name ghrunner-vm-01
```

---

← **Previous:** [GitHub Auth & Tokens](05-github-auth-tokens.md) | **Next:** [VM Automation](07-vm-automation.md) →
