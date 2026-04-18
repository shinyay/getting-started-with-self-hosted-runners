@description('Azure region for all resources')
param location string

@description('Name of the user-assigned managed identity')
param identityName string

@description('Role definition ID to assign (defaults to Contributor)')
param roleDefinitionId string = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

// ──────────────────────────────────────────────
// User-Assigned Managed Identity
// ──────────────────────────────────────────────

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// ──────────────────────────────────────────────
// Role Assignment — Contributor on resource group
// ──────────────────────────────────────────────

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, roleDefinitionId)
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalType: 'ServicePrincipal'
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────

@description('Resource ID of the managed identity')
output identityId string = managedIdentity.id

@description('Principal ID (object ID) of the managed identity')
output principalId string = managedIdentity.properties.principalId

@description('Client ID (application ID) of the managed identity')
output clientId string = managedIdentity.properties.clientId
