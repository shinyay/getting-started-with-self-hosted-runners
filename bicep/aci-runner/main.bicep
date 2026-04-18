// -------------------------------------------------------
// Azure Container Instances — GitHub Actions Self-Hosted Runner
// -------------------------------------------------------

@description('Azure region for the container group')
param location string = resourceGroup().location

@description('Name of the container group')
param containerGroupName string = 'ghrunner-aci'

@description('Name of the Azure Container Registry')
param acrName string

@description('Login server of the Azure Container Registry (e.g. myacr.azurecr.io)')
param acrLoginServer string

@description('Name of the container image')
param imageName string = 'ghrunner'

@description('Tag of the container image')
param imageTag string = 'latest'

@description('GitHub repository or organization URL')
param githubUrl string

@secure()
@description('GitHub Actions runner registration token')
param runnerToken string

@description('Name for the self-hosted runner')
param runnerName string

@description('Comma-separated labels for the runner')
param runnerLabels string = 'azure,linux,x64,aci'

@description('Number of CPU cores for the container')
param cpuCores int = 2

@description('Memory in GB for the container')
param memoryInGb int = 4

@description('Restart policy for the container group')
@allowed([
  'Always'
  'OnFailure'
  'Never'
])
param restartPolicy string = 'OnFailure'

// -------------------------------------------------------
// Reference to existing ACR for credentials
// -------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// -------------------------------------------------------
// Container Group
// -------------------------------------------------------
resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  properties: {
    osType: 'Linux'
    restartPolicy: restartPolicy
    imageRegistryCredentials: [
      {
        server: acrLoginServer
        username: acr.listCredentials().username
        password: acr.listCredentials().passwords[0].value
      }
    ]
    containers: [
      {
        name: runnerName
        properties: {
          image: '${acrLoginServer}/${imageName}:${imageTag}'
          resources: {
            requests: {
              cpu: cpuCores
              memoryInGB: memoryInGb
            }
          }
          environmentVariables: [
            {
              name: 'GITHUB_URL'
              value: githubUrl
            }
            {
              name: 'RUNNER_NAME'
              value: runnerName
            }
            {
              name: 'RUNNER_LABELS'
              value: runnerLabels
            }
            {
              name: 'RUNNER_TOKEN'
              secureValue: runnerToken
            }
          ]
        }
      }
    ]
  }
}

// -------------------------------------------------------
// Outputs
// -------------------------------------------------------
output containerGroupId string = containerGroup.id
output containerName string = runnerName
output ipAddress string = containerGroup.properties.?ipAddress.?ip ?? 'No public IP assigned'
