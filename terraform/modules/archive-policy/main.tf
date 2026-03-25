data "azurerm_subscription" "current" {}

locals {
  scope = data.azurerm_subscription.current.id
}

# --- Policy Definition: Deny new resource creation in archived resource groups ---

resource "azurerm_policy_definition" "deny_create_in_archive" {
  name         = "deny-create-in-archive-rg"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Deny new resource creation in archived resource groups"
  description  = "Prevents creation of new resources in resource groups tagged as archived (ArchiveProject=ArchiveLegacy)"

  metadata = jsonencode({
    category = "AzureArchive"
    version  = "1.0.0"
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field  = "type"
          notEquals = "Microsoft.Resources/subscriptions/resourceGroups"
        },
        {
          value = "[resourceGroup().tags['ArchiveProject']]"
          equals = "ArchiveLegacy"
        }
      ]
    }
    then = {
      effect = "Deny"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "deny_create_in_archive" {
  name                 = "deny-create-archive-rg"
  subscription_id      = local.scope
  policy_definition_id = azurerm_policy_definition.deny_create_in_archive.id
  display_name         = "Deny new resource creation in archived resource groups"
  description          = "Blocks creation of new resources in resource groups tagged ArchiveProject=ArchiveLegacy"
  enforce              = true
}

# --- Policy Definition: Deny scaling up of archived resources ---

resource "azurerm_policy_definition" "deny_scale_up_archive" {
  name         = "deny-scale-up-archive"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Deny scaling up of archived resources"
  description  = "Prevents increasing SKU tier or capacity on resources tagged as archived"

  metadata = jsonencode({
    category = "AzureArchive"
    version  = "1.0.0"
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field  = "tags['ArchiveProject']"
          equals = "ArchiveLegacy"
        },
        {
          anyOf = [
            {
              field = "Microsoft.Compute/virtualMachines/sku.name"
              notEquals = "[field('Microsoft.Compute/virtualMachines/sku.name')]"
            },
            {
              field    = "Microsoft.Web/serverfarms/sku.name"
              notEquals = "F1"
            },
            {
              field    = "Microsoft.Sql/servers/databases/sku.name"
              notEquals = "Basic"
            }
          ]
        }
      ]
    }
    then = {
      effect = "Deny"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "deny_scale_up_archive" {
  name                 = "deny-scale-up-archive"
  subscription_id      = local.scope
  policy_definition_id = azurerm_policy_definition.deny_scale_up_archive.id
  display_name         = "Deny scaling up of archived resources"
  description          = "Prevents SKU or capacity increases on archived resources"
  enforce              = true
}

# --- Policy Definition: Audit changes to archived resources ---

resource "azurerm_policy_definition" "audit_archive_changes" {
  name         = "audit-archive-changes"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Audit any changes to archived resources"
  description  = "Audits all modifications to resources tagged as archived for compliance tracking"

  metadata = jsonencode({
    category = "AzureArchive"
    version  = "1.0.0"
  })

  policy_rule = jsonencode({
    if = {
      field  = "tags['ArchiveProject']"
      equals = "ArchiveLegacy"
    }
    then = {
      effect = "Audit"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "audit_archive_changes" {
  name                 = "audit-archive-changes"
  subscription_id      = local.scope
  policy_definition_id = azurerm_policy_definition.audit_archive_changes.id
  display_name         = "Audit changes to archived resources"
  description          = "Logs all modifications to archived resources for compliance review"
  enforce              = true
}

# --- Policy Definition: Deny re-enabling stopped services ---

resource "azurerm_policy_definition" "deny_reenable_stopped" {
  name         = "deny-reenable-stopped-archive"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Deny re-enabling stopped archived services"
  description  = "Prevents starting or re-enabling services that have been stopped as part of the archive process"

  metadata = jsonencode({
    category = "AzureArchive"
    version  = "1.0.0"
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field  = "tags['ArchiveProject']"
          equals = "ArchiveLegacy"
        },
        {
          anyOf = [
            {
              allOf = [
                {
                  field  = "type"
                  equals = "Microsoft.Web/sites"
                },
                {
                  field    = "Microsoft.Web/sites/state"
                  notEquals = "Stopped"
                }
              ]
            },
            {
              allOf = [
                {
                  field  = "type"
                  equals = "Microsoft.Compute/virtualMachines"
                },
                {
                  field    = "Microsoft.Compute/virtualMachines/instanceView.statuses[*].code"
                  notEquals = "PowerState/deallocated"
                }
              ]
            }
          ]
        }
      ]
    }
    then = {
      effect = "Deny"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "deny_reenable_stopped" {
  name                 = "deny-reenable-stopped-arch"
  subscription_id      = local.scope
  policy_definition_id = azurerm_policy_definition.deny_reenable_stopped.id
  display_name         = "Deny re-enabling stopped archived services"
  description          = "Blocks starting VMs or App Services that were stopped during archival"
  enforce              = true
}
