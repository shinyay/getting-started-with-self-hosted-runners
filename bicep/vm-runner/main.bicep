// ──────────────────────────────────────────────
// Parameters
// ──────────────────────────────────────────────

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Name of the virtual machine')
param vmName string = 'ghrunner-vm-01'

@description('Size of the virtual machine')
param vmSize string = 'Standard_B2s'

@description('Admin username for the VM')
param adminUsername string = 'azureuser'

@description('SSH public key for authentication')
@secure()
param sshPublicKey string

@description('Address prefix for the virtual network')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Address prefix for the subnet')
param subnetPrefix string = '10.0.1.0/24'

@description('Source IP address or range allowed for SSH access')
param allowedSshSource string = '*'

@description('GitHub repository or organization URL')
param githubUrl string

@description('Runner registration token')
@secure()
param runnerToken string

@description('Name for the self-hosted runner')
param runnerName string

@description('Comma-separated labels for the runner')
param runnerLabels string = 'azure,linux,x64,vm'

// ──────────────────────────────────────────────
// Variables
// ──────────────────────────────────────────────

var cloudInitRaw = loadTextContent('../../scripts/vm/cloud-init-runner.yaml')
var cloudInitConfigured = replace(
  replace(
    replace(
      replace(cloudInitRaw, '__GITHUB_URL__', githubUrl),
      '__RUNNER_TOKEN__', runnerToken
    ),
    '__RUNNER_NAME__', runnerName
  ),
  '__RUNNER_LABELS__', runnerLabels
)

// ──────────────────────────────────────────────
// Modules
// ──────────────────────────────────────────────

module network '../modules/network.bicep' = {
  name: 'network-deployment'
  params: {
    location: location
    vnetName: '${vmName}-vnet'
    vnetAddressPrefix: vnetAddressPrefix
    subnetName: '${vmName}-subnet'
    subnetPrefix: subnetPrefix
    nsgName: '${vmName}-nsg'
    allowedSshSource: allowedSshSource
  }
}

module identity '../modules/identity.bicep' = {
  name: 'identity-deployment'
  params: {
    location: location
    identityName: '${vmName}-identity'
  }
}

// ──────────────────────────────────────────────
// Public IP
// ──────────────────────────────────────────────

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  tags: {
    purpose: 'github-runner'
    'managed-by': 'bicep'
  }
}

// ──────────────────────────────────────────────
// Network Interface
// ──────────────────────────────────────────────

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: network.outputs.subnetId
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: network.outputs.nsgId
    }
  }
  tags: {
    purpose: 'github-runner'
    'managed-by': 'bicep'
  }
}

// ──────────────────────────────────────────────
// Virtual Machine
// ──────────────────────────────────────────────

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.outputs.identityId}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInitConfigured)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
  tags: {
    purpose: 'github-runner'
    'managed-by': 'bicep'
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────

@description('Name of the deployed VM')
output vmName string = vm.name

@description('Public IP address of the VM')
output publicIpAddress string = publicIp.properties.ipAddress

@description('SSH command to connect to the VM')
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
