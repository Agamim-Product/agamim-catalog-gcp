# Catalog environment: stg. Resource group rg-agamim-catalog-stg-ilc (Israel Central).
module "env" {
  source = "../../modules/catalog_env"

  env                 = "stg"
  resource_group_name = "rg-agamim-catalog-stg-ilc"

  names = {
    lake          = "agamimlakestgdc3eee23"
    key_vault     = "kv-agamim-stg-dc3eee23"
    sql_server    = "sql-agamim-stg-dc3eee23"
    data_factory  = "adf-agamim-stg-dc3eee23"
    app_plan      = "asp-agamim-catalog-stg"
    web_app       = "app-agamim-catalog-stg-dc3eee23"
    log_workspace = "log-agamim-catalog-stg"
    app_insights  = "appi-agamim-catalog-stg"
  }

  sql_entra_admin         = { login = var.sql_admin_login, object_id = var.sql_admin_object_id }
  sql_legacy_admin_login  = null
  app_sku                 = "F1"
  lake_shared_key_enabled = false
  log_daily_quota_gb      = 0.1
  alerts_enabled          = false
  alert_email             = var.alert_email
}
