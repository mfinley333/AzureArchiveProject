output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.archive.id
}

output "action_group_id" {
  description = "Resource ID of the archive alerts action group"
  value       = azurerm_monitor_action_group.archive_alerts.id
}

output "resource_group_name" {
  description = "Name of the monitoring resource group"
  value       = azurerm_resource_group.monitoring.name
}
