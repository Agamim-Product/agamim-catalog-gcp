# Set outside the code (TF_VAR_... locally, GitHub Environment variables in CI): the repository is public.
variable "sql_admin_login" {
  type        = string
  description = "Entra ID sign-in name of the SQL administrator."
}

variable "sql_admin_object_id" {
  type        = string
  description = "Entra ID object ID of the SQL administrator."
}

variable "alert_email" {
  type    = string
  default = ""
}
