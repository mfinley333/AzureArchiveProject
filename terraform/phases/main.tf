module "archive_monitoring" {
  source = "../modules/archive-monitoring"

  location              = var.location
  notification_email    = var.notification_email
  alert_action_group_name = var.alert_action_group_name
  tags                  = var.tags
}

module "archive_policy" {
  source = "../modules/archive-policy"

  subscription_ids                = var.subscription_ids
  archive_resource_group_patterns = var.archive_resource_group_patterns
  log_analytics_workspace_id      = module.archive_monitoring.log_analytics_workspace_id
  tags                            = var.tags
}
