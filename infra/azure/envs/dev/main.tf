# Catalog environment: dev. Resource group rg-agamim-catalog-dev-ilc (Israel Central).
module "env" {
  source = "../../modules/catalog_env"

  env                 = "dev"
  resource_group_name = "rg-agamim-catalog-dev-ilc"

  names = {
    lake          = "agamimlakedevdc3eee23"
    key_vault     = "kv-agamim-dev-dc3eee23"
    sql_server    = "sql-agamim-dev-dc3eee23"
    data_factory  = "adf-agamim-dev-dc3eee23"
    app_plan      = "asp-agamim-catalog-dev"
    web_app       = "app-agamim-catalog-dev-dc3eee23"
    log_workspace = "log-agamim-catalog-dev"
    app_insights  = "appi-agamim-catalog-dev"
  }

  sql_entra_admin         = { login = var.sql_admin_login, object_id = var.sql_admin_object_id }
  sql_legacy_admin_login  = null
  app_sku                 = "F1"
  lake_shared_key_enabled = false
  log_daily_quota_gb      = 0.1
  alerts_enabled          = false
  alert_email             = var.alert_email
}
