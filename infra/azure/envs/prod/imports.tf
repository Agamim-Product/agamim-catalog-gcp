# The prod resources existed before Terraform (moved here from agamim-catalog-rg on 2026-11-17).
# These blocks adopt them into state on the first apply, so nothing is recreated.
# They are harmless after that: an import of something already in state is skipped.

data "azurerm_subscription" "current" {}

locals {
  rg_id = "${data.azurerm_subscription.current.id}/resourceGroups/rg-agamim-catalog-prod-ilc"
}

import {
  to = module.env.azurerm_storage_account.lake
  id = "${local.rg_id}/providers/Microsoft.Storage/storageAccounts/agamimlanddc3eee23"
}

import {
  to = module.env.azurerm_storage_container.landing
  id = "${local.rg_id}/providers/Microsoft.Storage/storageAccounts/agamimlanddc3eee23/blobServices/default/containers/landing"
}

import {
  to = module.env.azurerm_key_vault.this
  id = "${local.rg_id}/providers/Microsoft.KeyVault/vaults/agamim-kv-dc3eee23"
}

import {
  to = module.env.azurerm_mssql_server.this
  id = "${local.rg_id}/providers/Microsoft.Sql/servers/agamim-sql-dc3eee23"
}

import {
  to = module.env.azurerm_mssql_firewall_rule.azure_services
  id = "${local.rg_id}/providers/Microsoft.Sql/servers/agamim-sql-dc3eee23/firewallRules/AllowAzureServices"
}

import {
  to = module.env.azurerm_mssql_database.gold
  id = "${local.rg_id}/providers/Microsoft.Sql/servers/agamim-sql-dc3eee23/databases/gold"
}

import {
  to = module.env.azurerm_data_factory.this
  id = "${local.rg_id}/providers/Microsoft.DataFactory/factories/agamim-adf-dc3eee23"
}

import {
  to = module.env.azurerm_service_plan.this
  id = "${local.rg_id}/providers/Microsoft.Web/serverFarms/agamim-catalog-plan"
}

# The Data Factory identity's two role assignments, re-created after the move.
import {
  to = module.env.azurerm_role_assignment.adf_lake
  id = "${local.rg_id}/providers/Microsoft.Storage/storageAccounts/agamimlanddc3eee23/providers/Microsoft.Authorization/roleAssignments/a6502d22-4fb4-4a25-b037-f2f2d6a8644e"
}

import {
  to = module.env.azurerm_role_assignment.adf_secrets
  id = "${local.rg_id}/providers/Microsoft.KeyVault/vaults/agamim-kv-dc3eee23/providers/Microsoft.Authorization/roleAssignments/e71b6639-09f7-49d0-99d7-7253d6d85b22"
}

# Not managed here, on purpose: the old Node site (agamim-catalog-dc3eee23) and its database `catalog`,
# the portal dashboard, your own Key Vault role, and the developer-IP firewall rules. They are retired
# separately once the new site is live.

import {
  to = module.env.azurerm_storage_management_policy.lake
  id = "${local.rg_id}/providers/Microsoft.Storage/storageAccounts/agamimlanddc3eee23/managementPolicies/default"
}
