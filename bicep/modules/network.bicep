@description('Azure region for all resources')
param location string

@description('Name of the virtual network')
param vnetName string

@description('Address prefix for the virtual network')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Name of the subnet')
param subnetName string

@description('Address prefix for the subnet')
param subnetPrefix string = '10.0.1.0/24'

@description('Name of the network security group')
param nsgName string

@description('Source IP address or range allowed for SSH access')
param allowedSshSource string = '*'

// ──────────────────────────────────────────────
// Network Security Group
// ──────────────────────────────────────────────

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: allowedSshSource
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHTTPSOutbound'
        properties: {
          priority: 1000
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Virtual Network + Subnet
// ──────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────

@description('Resource ID of the subnet')
output subnetId string = vnet.properties.subnets[0].id

@description('Resource ID of the network security group')
output nsgId string = nsg.id

@description('Resource ID of the virtual network')
output vnetId string = vnet.id
