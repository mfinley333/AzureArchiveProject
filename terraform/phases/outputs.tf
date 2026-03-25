output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace for archive monitoring"
  value       = module.archive_monitoring.log_analytics_workspace_id
}

output "action_group_id" {
  description = "Resource ID of the archive alerts action group"
  value       = module.archive_monitoring.action_group_id
}

output "policy_assignment_ids" {
  description = "Map of policy assignment names to their resource IDs"
  value       = module.archive_policy.policy_assignment_ids
}
