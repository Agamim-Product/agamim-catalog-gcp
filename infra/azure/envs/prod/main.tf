# Catalog environment: prod. Resource group rg-agamim-catalog-prod-ilc (Israel Central).
module "env" {
  source = "../../modules/catalog_env"

  env                 = "prod"
  resource_group_name = "rg-agamim-catalog-prod-ilc"

  names = {
    lake          = "agamimlanddc3eee23"
    key_vault     = "agamim-kv-dc3eee23"
    sql_server    = "agamim-sql-dc3eee23"
    data_factory  = "agamim-adf-dc3eee23"
    app_plan      = "agamim-catalog-plan"
    web_app       = "app-agamim-catalog-prod-dc3eee23"
    log_workspace = "log-agamim-catalog-prod"
    app_insights  = "appi-agamim-catalog-prod"
  }

  sql_entra_admin         = { login = var.sql_admin_login, object_id = var.sql_admin_object_id }
  sql_legacy_admin_login  = "agamimadmin"
  app_sku                 = "B1"
  lake_shared_key_enabled = false
  log_daily_quota_gb      = -1
  alerts_enabled          = true
  alert_email             = var.alert_email
}
