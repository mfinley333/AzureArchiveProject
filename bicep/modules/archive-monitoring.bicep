@description('Azure region for all monitoring resources.')
param location string

@description('Email address for alert notifications.')
param notificationEmail string

@description('Tag value used to identify archived resources.')
@minLength(1)
param archiveTagValue string

@description('Monthly budget limit in USD for archived resources.')
param monthlyBudgetAmount int = 500

@description('Budget start date in yyyy-MM-dd format.')
param budgetStartDate string = utcNow('yyyy-MM-01')

// ──────────────────────────────────────────────
// Log Analytics Workspace
// ──────────────────────────────────────────────
@description('Log Analytics workspace for archived-resource telemetry.')
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-azure-archive'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ──────────────────────────────────────────────
// Action Group
// ──────────────────────────────────────────────
@description('Action group that emails the cloud engineering team.')
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-azure-archive'
  location: 'global'
  properties: {
    groupShortName: 'AzArchive'
    enabled: true
    emailReceivers: [
      {
        name: 'CloudEngTeam'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ──────────────────────────────────────────────
// Activity Log Alert – write/delete on archived resources
// ──────────────────────────────────────────────
@description('Fires on write or delete operations targeting archived resources.')
resource activityLogAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-archive-activity'
  location: 'global'
  properties: {
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'resourceType'
          equals: 'Microsoft.Resources/subscriptions/resourceGroups'
        }
        {
          field: 'operationName'
          containsAny: [
            'Microsoft.Resources/subscriptions/resourceGroups/write'
            'Microsoft.Resources/subscriptions/resourceGroups/delete'
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    description: 'Alert on write/delete operations in archived resource groups.'
  }
}

// ──────────────────────────────────────────────
// Scheduled Query Rule – detect traffic on archived resources
// ──────────────────────────────────────────────
@description('Detects unexpected network or request traffic on archived resources.')
resource scheduledQueryRule 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'sqr-archive-traffic'
  location: location
  properties: {
    displayName: 'Archived Resource Traffic Detection'
    description: 'Alerts when traffic is detected on resources tagged as archived.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    scopes: [
      logAnalytics.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
            AzureDiagnostics
            | where Tags_s contains "${archiveTagValue}"
            | where TimeGenerated > ago(1h)
            | summarize RequestCount = count() by Resource, ResourceType
            | where RequestCount > 0
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// ──────────────────────────────────────────────
// Budget Alert
// ──────────────────────────────────────────────
@description('Budget alert for cost monitoring of archived resources.')
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-azure-archive'
  properties: {
    category: 'Cost'
    amount: monthlyBudgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    filter: {
      tags: {
        name: 'ArchiveProject'
        values: [
          archiveTagValue
        ]
      }
    }
    notifications: {
      actual80Pct: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        contactGroups: [
          actionGroup.id
        ]
        thresholdType: 'Actual'
      }
      forecast100Pct: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        contactGroups: [
          actionGroup.id
        ]
        thresholdType: 'Forecasted'
      }
    }
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceId string = logAnalytics.id

@description('Resource ID of the action group.')
output actionGroupId string = actionGroup.id
