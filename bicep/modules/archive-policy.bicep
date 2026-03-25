targetScope = 'subscription'

@description('Tag value used to identify archived resource groups.')
@minLength(1)
param archiveTagValue string

@description('Azure region for policy assignment metadata.')
param location string

// ════════════════════════════════════════════════
// Policy Definition: Deny new resource creation
// ════════════════════════════════════════════════
@description('Denies creation of new resources in archived resource groups.')
resource denyNewResources 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: 'deny-new-resources-archived-rg'
  properties: {
    displayName: 'Deny new resource creation in archived resource groups'
    description: 'Prevents provisioning of new resources in resource groups tagged with ArchiveProject=${archiveTagValue}.'
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Archive Governance'
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            notEquals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            value: '[resourceGroup().tags[\'ArchiveProject\']]'
            equals: archiveTagValue
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

// ════════════════════════════════════════════════
// Policy Definition: Deny scaling up
// ════════════════════════════════════════════════
@description('Denies SKU/capacity increases on archived resources.')
resource denyScaleUp 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: 'deny-scaleup-archived-resources'
  properties: {
    displayName: 'Deny scaling up archived resources'
    description: 'Prevents increasing the SKU or capacity of resources tagged with ArchiveProject=${archiveTagValue}.'
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Archive Governance'
    }
    parameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'Policy effect.'
        }
        allowedValues: [
          'deny'
          'audit'
          'disabled'
        ]
        defaultValue: 'deny'
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'tags[\'ArchiveProject\']'
            equals: archiveTagValue
          }
          {
            anyOf: [
              {
                field: 'Microsoft.Compute/virtualMachines/sku.name'
                notEquals: '[field(\'Microsoft.Compute/virtualMachines/sku.name\')]'
              }
              {
                field: 'Microsoft.Sql/servers/databases/sku.name'
                notEquals: '[field(\'Microsoft.Sql/servers/databases/sku.name\')]'
              }
              {
                field: 'Microsoft.Web/serverfarms/sku.name'
                notEquals: '[field(\'Microsoft.Web/serverfarms/sku.name\')]'
              }
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

// ════════════════════════════════════════════════
// Policy Definition: Audit changes
// ════════════════════════════════════════════════
@description('Audits any modifications to archived resources.')
resource auditChanges 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: 'audit-changes-archived-resources'
  properties: {
    displayName: 'Audit changes to archived resources'
    description: 'Audits write operations on resources tagged with ArchiveProject=${archiveTagValue}.'
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Archive Governance'
    }
    policyRule: {
      if: {
        field: 'tags[\'ArchiveProject\']'
        equals: archiveTagValue
      }
      then: {
        effect: 'audit'
      }
    }
  }
}

// ════════════════════════════════════════════════
// Policy Assignments
// ════════════════════════════════════════════════
@description('Assigns the deny-new-resources policy at subscription scope.')
resource assignDenyNewResources 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'assign-deny-new-resources-archived'
  location: location
  properties: {
    displayName: 'Deny new resources in archived RGs'
    policyDefinitionId: denyNewResources.id
    enforcementMode: 'Default'
  }
}

@description('Assigns the deny-scale-up policy at subscription scope.')
resource assignDenyScaleUp 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'assign-deny-scaleup-archived'
  location: location
  properties: {
    displayName: 'Deny scale-up on archived resources'
    policyDefinitionId: denyScaleUp.id
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'deny'
      }
    }
  }
}

@description('Assigns the audit-changes policy at subscription scope.')
resource assignAuditChanges 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'assign-audit-changes-archived'
  location: location
  properties: {
    displayName: 'Audit changes to archived resources'
    policyDefinitionId: auditChanges.id
    enforcementMode: 'Default'
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
@description('Policy definition IDs.')
output policyDefinitionIds object = {
  denyNewResources: denyNewResources.id
  denyScaleUp: denyScaleUp.id
  auditChanges: auditChanges.id
}
