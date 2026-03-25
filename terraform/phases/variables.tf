variable "subscription_ids" {
  description = "List of Azure subscription IDs to apply archive policies to"
  type        = list(string)
}

variable "archive_resource_group_patterns" {
  description = "List of resource group name patterns that contain archived resources (e.g., ['rg-azure-archive-*'])"
  type        = list(string)
  default     = ["rg-azure-archive-*"]
}

variable "notification_email" {
  description = "Email address for archive monitoring notifications"
  type        = string
}

variable "alert_action_group_name" {
  description = "Name of the Azure Monitor action group for archive alerts"
  type        = string
  default     = "ag-azure-archive-alerts"
}

variable "location" {
  description = "Azure region for monitoring resources"
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Tags to apply to all Phase 5 resources"
  type        = map(string)
  default = {
    ArchiveProject = "ArchiveLegacy"
    Phase          = "5-MonitoringPolicy"
    ManagedBy      = "Terraform"
  }
}
