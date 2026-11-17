variable "github_repository" {
  type        = string
  default     = "Agamim-Product/agamim-catalog-gcp"
  description = "owner/repo whose GitHub Actions may sign in."
}

variable "state_account_name" {
  type    = string
  default = "agamimtfdc3eee23"
}

variable "operator_object_id" {
  type        = string
  description = "Entra ID object ID of the person who runs Terraform locally (set via TF_VAR_operator_object_id)."
}
