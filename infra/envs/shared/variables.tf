variable "project_id" {
  type    = string
  default = "agamim-catalog-prod-il"
}

# Israel (Tel Aviv).
variable "region" {
  type    = string
  default = "me-west1"
}

variable "domain" {
  type    = string
  default = ""
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "ci_deployer_service_account" {
  type        = string
  default     = "gh-terraform@agamim-catalog-prod-il.iam.gserviceaccount.com"
  description = "Service account GitHub Actions impersonates to apply Terraform and deploy."
}
