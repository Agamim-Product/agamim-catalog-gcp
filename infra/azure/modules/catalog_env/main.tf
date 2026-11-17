# One catalog environment (dev, stg or prod) in its own resource group:
#   data lake (bronze) -> Data Factory (ingest + ETL) -> Azure SQL (silver + gold) -> App Service (site + API)
# plus Key Vault, Log Analytics / Application Insights and alerts.
# Every service signs in with its managed identity; nothing here creates a password.

locals {
  tags = merge(var.tags, { app = "agamim-catalog", env = var.env, managed-by = "terraform" })
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "env" {
  name = var.resource_group_name
}

# ---------- Bronze: data lake ----------
resource "azurerm_storage_account" "lake" {
  name                            = var.names.lake
  resource_group_name             = data.azurerm_resource_group.env.name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  access_tier                     = "Hot"
  is_hns_enabled                  = true # Data Lake Storage Gen2
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = var.lake_shared_key_enabled
  local_user_enabled              = false
  tags                            = local.tags

  blob_properties {
    delete_retention_policy { days = 7 } # deleted raw files can be restored for a week
    container_delete_retention_policy { days = 7 }
  }

  sas_policy {
    expiration_period = "01.00:00:00" # any SAS token is valid for a day at most
    expiration_action = "Log"
  }
}

resource "azurerm_storage_container" "landing" {
  name                  = "landing"
  storage_account_id    = azurerm_storage_account.lake.id
  container_access_type = "private"
}

# Raw files are kept (gold can be rebuilt from them) but move to the Cool tier after 30 days.
resource "azurerm_storage_management_policy" "lake" {
  storage_account_id = azurerm_storage_account.lake.id
  rule {
    name    = "hot-to-cool-30d"
    enabled = true
    filters {
      prefix_match = ["landing/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = 30
      }
    }
  }
}

# ---------- Secrets ----------
resource "azurerm_key_vault" "this" {
  name                       = var.names.key_vault
  resource_group_name        = data.azurerm_resource_group.env.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

# ---------- Silver + gold: Azure SQL ----------
resource "azurerm_mssql_server" "this" {
  name                          = var.names.sql_server
  resource_group_name           = data.azurerm_resource_group.env.name
  location                      = var.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  administrator_login           = var.sql_legacy_admin_login # null = Entra ID sign-in only
  tags                          = local.tags

  azuread_administrator {
    login_username              = var.sql_entra_admin.login
    object_id                   = var.sql_entra_admin.object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = var.sql_legacy_admin_login == null
  }

  # The legacy SQL login (prod only, used by the old site) keeps the password it already has.
  lifecycle { ignore_changes = [administrator_login_password] }
}

# Lets Azure services (Data Factory, App Service) reach the server. Access still needs an Entra ID identity.
resource "azurerm_mssql_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_database" "gold" {
  name                 = "gold"
  server_id            = azurerm_mssql_server.this.id
  sku_name             = var.sql_sku
  max_size_gb          = var.sql_max_size_gb
  collation            = "SQL_Latin1_General_CP1_CI_AS"
  storage_account_type = "Local"
  zone_redundant       = false
  tags                 = local.tags
}

# ---------- Ingest + ETL: Data Factory ----------
resource "azurerm_data_factory" "this" {
  name                   = var.names.data_factory
  resource_group_name    = data.azurerm_resource_group.env.name
  location               = var.location
  public_network_enabled = true
  tags                   = local.tags

  identity { type = "SystemAssigned" }
}

resource "azurerm_role_assignment" "adf_lake" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "adf_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# ---------- Website + API: App Service ----------
resource "azurerm_service_plan" "this" {
  name                = var.names.app_plan
  resource_group_name = data.azurerm_resource_group.env.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_sku
  tags                = local.tags
}

resource "azurerm_linux_web_app" "this" {
  name                = var.names.web_app
  resource_group_name = data.azurerm_resource_group.env.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id
  https_only          = true
  tags                = local.tags

  identity { type = "SystemAssigned" }

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  site_config {
    http2_enabled                     = true
    always_on                         = var.app_sku != "F1" # not available on the free tier
    ftps_state                        = "Disabled"
    minimum_tls_version               = "1.2"
    health_check_path                 = "/healthz"
    health_check_eviction_time_in_min = 5
    app_command_line                  = "python -m gunicorn catalog.api.app:app --worker-class uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000 --workers 2 --timeout 120"
    application_stack { python_version = "3.12" }
  }

  app_settings = {
    CATALOG_ENV                           = var.env
    SQL_SERVER                            = azurerm_mssql_server.this.fully_qualified_domain_name
    SQL_DATABASE                          = azurerm_mssql_database.gold.name
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
    SCM_DO_BUILD_DURING_DEPLOYMENT        = "false" # CI deploys a built package; nothing is built on the server
    WEBSITES_PORT                         = "8000"
    PYTHONPATH                            = "/home/site/wwwroot/vendor:/home/site/wwwroot/src" # the package ships its dependencies
    STATIC_DIR                            = "/home/site/wwwroot/site"                          # the built website
  }
}

resource "azurerm_role_assignment" "app_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# ---------- Monitoring ----------
resource "azurerm_log_analytics_workspace" "this" {
  name                = var.names.log_workspace
  resource_group_name = data.azurerm_resource_group.env.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = var.names.app_insights
  resource_group_name = data.azurerm_resource_group.env.name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "adf" {
  name                           = "to-log-analytics"
  target_resource_id             = azurerm_data_factory.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "PipelineRuns" }
  enabled_log { category = "ActivityRuns" }
  enabled_log { category = "TriggerRuns" }
}

resource "azurerm_monitor_action_group" "email" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "ag-agamim-catalog-${var.env}"
  resource_group_name = data.azurerm_resource_group.env.name
  short_name          = "catalog${var.env}"
  tags                = local.tags

  email_receiver {
    name          = "owner"
    email_address = var.alert_email
  }
}

resource "azurerm_monitor_metric_alert" "pipeline_failed" {
  name                = "alert-pipeline-failed-${var.env}"
  resource_group_name = data.azurerm_resource_group.env.name
  scopes              = [azurerm_data_factory.this.id]
  description         = "A Data Factory pipeline run failed. Gold keeps its last good state."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"
  enabled             = var.alerts_enabled
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.DataFactory/factories"
    metric_name      = "PipelineFailedRuns"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  dynamic "action" {
    for_each = azurerm_monitor_action_group.email
    content { action_group_id = action.value.id }
  }
}
