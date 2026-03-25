targetScope = 'subscription'

// ──────────────────────────────────────────────
// Parameters
// ──────────────────────────────────────────────
@description('Azure region for deployed resources.')
@allowed([
  'eastus'
  'eastus2'
  'centralus'
  'westus2'
  'westeurope'
  'northeurope'
])
param location string

@description('Email address for alert notifications.')
param notificationEmail string

@description('Tag value identifying archived resources (e.g. ArchiveLegacy).')
@minLength(1)
param archiveTagValue string

@description('Name of the resource group for monitoring resources.')
@minLength(1)
param resourceGroupName string

@description('Object ID of the Cloud Engineering team AAD group.')
param cloudEngTeamObjectId string

// ──────────────────────────────────────────────
// Resource Group (ensure it exists)
// ──────────────────────────────────────────────
@description('Resource group for monitoring infrastructure.')
resource monitoringRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: {
    ArchiveProject: archiveTagValue
    ManagedBy: 'Bicep-Phase5'
  }
}

// ──────────────────────────────────────────────
// Module: Monitoring (resource group scope)
// ──────────────────────────────────────────────
@description('Deploys Log Analytics, alerts, and budget monitoring.')
module monitoring '../modules/archive-monitoring.bicep' = {
  name: 'deploy-archive-monitoring'
  scope: monitoringRg
  params: {
    location: location
    notificationEmail: notificationEmail
    archiveTagValue: archiveTagValue
  }
}

// ──────────────────────────────────────────────
// Module: Policy (subscription scope)
// ──────────────────────────────────────────────
@description('Deploys custom policy definitions and assignments.')
module policy '../modules/archive-policy.bicep' = {
  name: 'deploy-archive-policy'
  params: {
    location: location
    archiveTagValue: archiveTagValue
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
@description('Log Analytics workspace resource ID.')
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId

@description('Action group resource ID.')
output actionGroupId string = monitoring.outputs.actionGroupId

@description('Policy definition IDs.')
output policyDefinitionIds object = policy.outputs.policyDefinitionIds
