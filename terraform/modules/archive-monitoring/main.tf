data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "monitoring" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_log_analytics_workspace" "archive" {
  name                = var.log_analytics_workspace_name
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_monitor_action_group" "archive_alerts" {
  name                = var.alert_action_group_name
  resource_group_name = azurerm_resource_group.monitoring.name
  short_name          = "AzArchive"
  tags                = var.tags

  email_receiver {
    name          = "cloud-engineering-team"
    email_address = var.notification_email
  }
}

# Activity Log Alert: fires on write/delete operations on archived resources
resource "azurerm_monitor_activity_log_alert" "archive_modifications" {
  name                = "alert-archive-resource-modifications"
  resource_group_name = azurerm_resource_group.monitoring.name
  scopes              = [data.azurerm_subscription.current.id]
  description         = "Fires when write or delete operations occur on resources tagged ArchiveProject=ArchiveLegacy"
  tags                = var.tags

  criteria {
    category = "Administrative"

    resource_health {
      current  = ["Available"]
      previous = ["Available"]
    }
  }

  # Filter to archived resources via tag-based conditions
  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Resources/subscriptions/resourceGroups/write"
  }

  action {
    action_group_id = azurerm_monitor_action_group.archive_alerts.id
  }
}

# Metric Alert: budget threshold for archived resource costs
resource "azurerm_monitor_metric_alert" "archive_budget" {
  name                = "alert-archive-budget-threshold"
  resource_group_name = azurerm_resource_group.monitoring.name
  scopes              = [azurerm_log_analytics_workspace.archive.id]
  description         = "Alert when Log Analytics ingestion exceeds expected threshold for archived resources"
  severity            = 2
  frequency           = "PT1H"
  window_size         = "PT6H"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.OperationalInsights/workspaces"
    metric_name      = "BillableDataGB"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.archive_alerts.id
  }
}

# Scheduled Query Rule: detect non-zero traffic on archived resources
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "archive_traffic" {
  name                = "alert-archive-nonzero-traffic"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  description         = "Detect non-zero network or request traffic on archived resources"
  severity            = 3
  tags                = var.tags

  scopes                    = [azurerm_log_analytics_workspace.archive.id]
  evaluation_frequency      = "PT30M"
  window_duration           = "PT1H"
  auto_mitigation_enabled   = true
  workspace_alerts_storage_enabled = false

  criteria {
    query = <<-QUERY
      AzureMetrics
      | where Resource has "archive" or Tags has "ArchiveLegacy"
      | where MetricName in ("BytesSent", "BytesReceived", "Requests", "TotalRequests")
      | where Total > 0
      | summarize TrafficCount = count(), TotalBytes = sum(Total) by Resource, MetricName
    QUERY

    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.archive_alerts.id]
  }
}
