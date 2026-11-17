variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "stg", "prod"], var.env)
    error_message = "env must be dev, stg or prod."
  }
}

variable "resource_group_name" { type = string }

variable "location" {
  type    = string
  default = "israelcentral"
}

variable "names" {
  description = "Resource names. Storage, Key Vault, SQL and web app names must be globally unique."
  type = object({
    lake          = string
    key_vault     = string
    sql_server    = string
    data_factory  = string
    app_plan      = string
    web_app       = string
    log_workspace = string
    app_insights  = string
  })
}

variable "sql_entra_admin" {
  description = "Entra ID principal that administers the SQL server (creates the database users for the identities)."
  type        = object({ login = string, object_id = string })
}

variable "sql_legacy_admin_login" {
  description = "SQL login kept only where an existing app still uses it (prod). null = Entra ID sign-in only."
  type        = string
  default     = null
}

variable "sql_sku" {
  type    = string
  default = "Basic"
}

variable "sql_max_size_gb" {
  type    = number
  default = 2
}

variable "app_sku" {
  type        = string
  default     = "F1"
  description = "F1 (free) for dev and staging, B1 for prod."
}

variable "lake_shared_key_enabled" {
  type        = bool
  default     = false
  description = "Storage account keys. Off for new lakes: everything signs in with Entra ID."
}

variable "log_daily_quota_gb" {
  type        = number
  default     = -1
  description = "Daily Log Analytics ingestion cap in GB (-1 = no cap). Caps cost in dev and staging."
}

variable "alerts_enabled" {
  type    = bool
  default = false
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
