# Sample Workflows

Ready-to-use GitHub Actions workflow examples for self-hosted runners. Each workflow demonstrates a different pattern.

> [!TIP]
> The key difference from GitHub-hosted runners is the `runs-on` value. Instead of `ubuntu-latest`, use your self-hosted runner labels like `[self-hosted, linux, azure]`.

## 1. Basic CI (Build & Test)

**File:** `.github/workflows/self-hosted-ci.yml`

```yaml
name: CI — Self-Hosted Runner

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  build-and-test:
    runs-on: [self-hosted, linux, azure]
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: System Info
        run: |
          echo "Runner: ${RUNNER_NAME}"
          echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
          echo "Arch: $(uname -m)"
          echo "Docker: $(docker --version 2>/dev/null || echo 'not available')"

      - name: Run Tests
        run: |
          echo "Running tests..."
          # Replace with your actual test commands
          echo "All tests passed ✅"

      - name: Build
        run: |
          echo "Building project..."
          # Replace with your actual build commands
          echo "Build complete ✅"
```

**Key points:**

- **`runs-on: [self-hosted, linux, azure]`** — targets runners with **ALL** these labels. The job only runs on a runner that has every label in the list.
- **System Info step** — prints runner name, OS, architecture, and Docker availability. Useful for verifying which runner picked up the job.
- Replace the placeholder `echo` commands in the **Run Tests** and **Build** steps with your actual test and build commands.

## 2. Docker Build and Push to ACR

```yaml
name: Docker Build & Push

on:
  push:
    branches: [main]
    paths: ['containers/**']

permissions:
  id-token: write
  contents: read

jobs:
  build-and-push:
    runs-on: [self-hosted, linux, azure]
    steps:
      - uses: actions/checkout@v4

      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Login to ACR
        run: az acr login --name ${{ vars.ACR_NAME || 'ghrunneracr' }}

      - name: Build and Push
        run: |
          IMAGE="${{ vars.ACR_NAME || 'ghrunneracr' }}.azurecr.io/ghrunner"
          TAG="${{ github.sha }}"
          
          docker build -t "${IMAGE}:${TAG}" -t "${IMAGE}:latest" containers/runner/
          docker push "${IMAGE}:${TAG}"
          docker push "${IMAGE}:latest"
          
          echo "✅ Pushed ${IMAGE}:${TAG}"
```

> [!NOTE]
> Docker builds require Docker installed on the runner. This works on **VM** and **AKS (with DinD)** runners, but **NOT on ACI**.

## 3. Azure Deployment with OIDC

**File:** `.github/workflows/deploy-azure-oidc.yml`

```yaml
name: Deploy to Azure (OIDC)

on:
  push:
    branches: [main]
    paths:
      - 'bicep/**'
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  validate:
    name: Validate Bicep
    runs-on: [self-hosted, linux, azure]
    steps:
      - uses: actions/checkout@v4

      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Validate Template
        run: |
          az deployment group validate \
            --resource-group ${{ vars.AZURE_RESOURCE_GROUP || 'ghrunner-rg' }} \
            --template-file bicep/vm-runner/main.bicep \
            --parameters bicep/vm-runner/main.parameters.json

  deploy:
    name: Deploy Infrastructure
    needs: validate
    runs-on: [self-hosted, linux, azure]
    environment: production
    steps:
      - uses: actions/checkout@v4

      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Deploy Bicep
        run: |
          az deployment group create \
            --resource-group ${{ vars.AZURE_RESOURCE_GROUP || 'ghrunner-rg' }} \
            --template-file bicep/vm-runner/main.bicep \
            --parameters bicep/vm-runner/main.parameters.json \
            --name "deploy-$(date +%Y%m%d-%H%M%S)"

      - name: Verify Deployment
        run: |
          az vm list \
            --resource-group ${{ vars.AZURE_RESOURCE_GROUP || 'ghrunner-rg' }} \
            --output table
```

**Key points:**

- **`permissions: id-token: write`** — required for OIDC. Without this, the `azure/login` action cannot request a federated token.
- **Validate before deploy** — the `validate` job catches template errors before any resources are created. The `deploy` job uses `needs: validate` to enforce this order.
- **`environment: production`** — enables [environment protection rules](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) such as required reviewers, wait timers, and branch restrictions.
- **OIDC eliminates stored secrets** — no long-lived credentials are stored in GitHub. The runner exchanges a short-lived OIDC token with Azure AD for an access token.

## 4. Matrix Strategy

```yaml
name: Matrix Test

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  test:
    runs-on: [self-hosted, linux, azure]
    strategy:
      matrix:
        node-version: [18, 20, 22]
      fail-fast: false
    
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js ${{ matrix.node-version }}
        uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}

      - name: Install and Test
        run: |
          node --version
          npm --version
          # npm ci
          # npm test
          echo "Tests passed on Node.js ${{ matrix.node-version }} ✅"
```

**Key points:**

- **Matrix runs multiple jobs in parallel** — if you have multiple self-hosted runners available, each matrix combination runs on a separate runner simultaneously.
- **`fail-fast: false`** — continues running other matrix jobs even if one fails. This is useful to see which versions pass and which fail, rather than cancelling everything on the first failure.
- **`actions/setup-node` works on self-hosted runners** — it downloads and installs the requested Node.js version into the runner's tool cache (`_work/_tool/`). Subsequent runs reuse the cached version.

## 5. Reusable Workflow

Reusable workflows let you define a job once and call it from multiple workflows — keeping your CI/CD DRY.

### Called workflow

**File:** `.github/workflows/reusable-deploy.yml`

```yaml
name: Reusable Deploy

on:
  workflow_call:
    inputs:
      environment:
        required: true
        type: string
      resource-group:
        required: true
        type: string
    secrets:
      AZURE_CLIENT_ID:
        required: true
      AZURE_TENANT_ID:
        required: true
      AZURE_SUBSCRIPTION_ID:
        required: true

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: [self-hosted, linux, azure]
    environment: ${{ inputs.environment }}
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: |
          echo "Deploying to ${{ inputs.environment }}..."
          az group show --name ${{ inputs.resource-group }} --output table
```

### Caller workflow

```yaml
name: Deploy All Environments

on:
  push:
    branches: [main]

jobs:
  deploy-staging:
    uses: ./.github/workflows/reusable-deploy.yml
    with:
      environment: staging
      resource-group: ghrunner-staging-rg
    secrets: inherit

  deploy-production:
    needs: deploy-staging
    uses: ./.github/workflows/reusable-deploy.yml
    with:
      environment: production
      resource-group: ghrunner-production-rg
    secrets: inherit
```

**Key points:**

- **`workflow_call`** trigger makes a workflow reusable. It accepts `inputs` and `secrets` from the caller.
- **`secrets: inherit`** passes all of the caller's secrets to the reusable workflow without listing them individually.
- The caller uses `needs: deploy-staging` to deploy staging first, then production — a simple promotion pipeline.

## 6. Accessing Private Azure Resources

```yaml
name: Access Private Resources

on:
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  access-private:
    runs-on: [self-hosted, linux, azure, vnet]
    steps:
      - uses: actions/checkout@v4

      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Access Key Vault (Private Endpoint)
        run: |
          SECRET=$(az keyvault secret show \
            --vault-name ghrunner-kv \
            --name my-api-key \
            --query value -o tsv)
          echo "::add-mask::$SECRET"
          echo "✅ Successfully accessed Key Vault via private endpoint"

      - name: Query Private Database
        run: |
          # Example: access a database on private VNet
          # This only works because the runner is inside the VNet
          echo "✅ Runner has private network access"

      - name: Access Private Storage
        run: |
          az storage blob list \
            --account-name ghrunnerstore \
            --container-name artifacts \
            --auth-mode login \
            --output table
```

**Key points:**

- **`runs-on: [self-hosted, linux, azure, vnet]`** — the `vnet` label targets runners that are deployed inside an Azure Virtual Network.
- **Private endpoints** allow the runner to access Azure services (Key Vault, Storage, databases) over the VNet backbone without traversing the public internet.
- **This is a key advantage of self-hosted runners** over GitHub-hosted runners. GitHub-hosted runners cannot reach resources behind private endpoints or firewalls.

## Summary

| Workflow | Key Pattern | Works On |
|----------|-----------|----------|
| Basic CI | Simple build/test | All platforms |
| Docker Build | Container image CI | VM, AKS (DinD) |
| OIDC Deploy | Passwordless Azure auth | All platforms |
| Matrix | Parallel version testing | All platforms |
| Reusable | DRY workflow pattern | All platforms |
| Private Access | VNet resource access | VM (VNet), AKS (VNet) |

---

← **Previous:** [Monitoring & Maintenance](12-monitoring-maintenance.md) | **Next:** [Advanced Enterprise](14-advanced-enterprise.md) →
