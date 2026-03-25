variable "subscription_ids" {
  description = "List of subscription IDs to apply archive policies to"
  type        = list(string)
}

variable "archive_resource_group_patterns" {
  description = "Resource group name patterns identifying archived resource groups"
  type        = list(string)
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace for policy compliance logs"
  type        = string
}

variable "tags" {
  description = "Tags to apply to policy resources"
  type        = map(string)
  default     = {}
}
