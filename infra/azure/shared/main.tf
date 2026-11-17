# Shared by all environments:
#   - Terraform state storage (Entra ID access only, versioned, no storage keys)
#   - one GitHub Actions identity per environment (OIDC federated credentials, no secrets), each allowed to
#     manage only its own resource group, plus a read-only identity for pull-request plans.

locals {
  location = "israelcentral"
  tags     = { app = "agamim-catalog", env = "shared", managed-by = "terraform" }
  github   = "repo:${var.github_repository}"

  # GitHub Environment -> resource group it may change
  deployers = {
    dev  = { github_environment = "dev", resource_group = "rg-agamim-catalog-dev-ilc" }
    stg  = { github_environment = "staging", resource_group = "rg-agamim-catalog-stg-ilc" }
    prod = { github_environment = "production", resource_group = "rg-agamim-catalog-prod-ilc" }
  }
}

data "azurerm_resource_group" "env" {
  for_each = local.deployers
  name     = each.value.resource_group
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-agamim-catalog-shared-ilc"
  location = local.location
  tags     = local.tags
}

# ---------- Terraform state ----------
resource "azurerm_storage_account" "tfstate" {
  name                            = var.state_account_name
  resource_group_name             = azurerm_resource_group.shared.name
  location                        = local.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  tags                            = local.tags

  blob_properties {
    versioning_enabled = true # every state version is kept, so a bad apply can be rolled back
    delete_retention_policy { days = 30 }
    container_delete_retention_policy { days = 30 }
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# ---------- GitHub Actions identities ----------
resource "azurerm_user_assigned_identity" "deployer" {
  for_each            = local.deployers
  name                = "id-agamim-catalog-deploy-${each.key}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.location
  tags                = local.tags
}

# Only a workflow job running in the matching GitHub Environment can sign in as this identity.
resource "azurerm_federated_identity_credential" "deployer" {
  for_each            = local.deployers
  name                = "github-${each.value.github_environment}"
  resource_group_name = azurerm_resource_group.shared.name
  parent_id           = azurerm_user_assigned_identity.deployer[each.key].id
  issuer              = "https://token.actions.githubusercontent.com"
  audience            = ["api://AzureADTokenExchange"]
  subject             = "${local.github}:environment:${each.value.github_environment}"
}

resource "azurerm_role_assignment" "deployer_contributor" {
  for_each             = local.deployers
  scope                = data.azurerm_resource_group.env[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.deployer[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# Needed to grant the environment's own managed identities their roles. Limited to the same resource group.
resource "azurerm_role_assignment" "deployer_rbac" {
  for_each             = local.deployers
  scope                = data.azurerm_resource_group.env[each.key].id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.deployer[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployer_state" {
  for_each             = local.deployers
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.deployer[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# Read-only identity for pull requests: terraform plan for every environment, no changes.
resource "azurerm_user_assigned_identity" "planner" {
  name                = "id-agamim-catalog-plan"
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "planner" {
  name                = "github-pull-request"
  resource_group_name = azurerm_resource_group.shared.name
  parent_id           = azurerm_user_assigned_identity.planner.id
  issuer              = "https://token.actions.githubusercontent.com"
  audience            = ["api://AzureADTokenExchange"]
  subject             = "${local.github}:pull_request"
}

resource "azurerm_role_assignment" "planner_read" {
  for_each             = local.deployers
  scope                = data.azurerm_resource_group.env[each.key].id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.planner.principal_id
  principal_type       = "ServicePrincipal"
}

# Reader cannot read web app settings: Azure files that read under a "list" action. This role adds exactly
# that one read action, in the three environment groups only (approved 2026-11-17).
resource "azurerm_role_definition" "planner_reads" {
  name        = "Agamim catalog Terraform plan reads"
  scope       = data.azurerm_resource_group.env["prod"].id
  description = "Read web app settings, which Terraform needs to plan. Nothing else."

  permissions {
    actions = ["Microsoft.Web/sites/config/list/action"]
  }

  assignable_scopes = [for rg in data.azurerm_resource_group.env : rg.id]
}

resource "azurerm_role_assignment" "planner_reads" {
  for_each           = local.deployers
  scope              = data.azurerm_resource_group.env[each.key].id
  role_definition_id = azurerm_role_definition.planner_reads.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.planner.principal_id
  principal_type     = "ServicePrincipal"
}

# Plans read state and take a short lock on it.
resource "azurerm_role_assignment" "planner_state" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.planner.principal_id
  principal_type       = "ServicePrincipal"
}

# You (the person running this) can read and write state locally too.
resource "azurerm_role_assignment" "operator_state" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.operator_object_id
}
