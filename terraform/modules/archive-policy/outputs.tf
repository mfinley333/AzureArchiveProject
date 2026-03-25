output "policy_assignment_ids" {
  description = "Map of policy assignment names to their resource IDs"
  value = {
    deny_create_in_archive = azurerm_subscription_policy_assignment.deny_create_in_archive.id
    deny_scale_up_archive  = azurerm_subscription_policy_assignment.deny_scale_up_archive.id
    audit_archive_changes  = azurerm_subscription_policy_assignment.audit_archive_changes.id
    deny_reenable_stopped  = azurerm_subscription_policy_assignment.deny_reenable_stopped.id
  }
}

output "policy_definition_ids" {
  description = "Map of custom policy definition names to their resource IDs"
  value = {
    deny_create_in_archive = azurerm_policy_definition.deny_create_in_archive.id
    deny_scale_up_archive  = azurerm_policy_definition.deny_scale_up_archive.id
    audit_archive_changes  = azurerm_policy_definition.audit_archive_changes.id
    deny_reenable_stopped  = azurerm_policy_definition.deny_reenable_stopped.id
  }
}
