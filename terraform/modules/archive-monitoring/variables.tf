variable "location" {
  description = "Azure region for monitoring resources"
  type        = string
}

variable "notification_email" {
  description = "Email address for archive alert notifications"
  type        = string
}

variable "alert_action_group_name" {
  description = "Display name of the action group"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group for archive monitoring resources"
  type        = string
  default     = "rg-azure-archive-monitoring"
}

variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace"
  type        = string
  default     = "law-azure-archive"
}

variable "log_retention_days" {
  description = "Number of days to retain logs in Log Analytics"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags to apply to all monitoring resources"
  type        = map(string)
  default     = {}
}
