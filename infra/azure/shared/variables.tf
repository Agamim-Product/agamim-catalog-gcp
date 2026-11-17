variable "github_repository" {
  type        = string
  default     = "Agamim-Product@353296930/agamim-catalog-gcp@1460541082"
  description = "owner@ownerId/repo@repoId as it appears in this repository's GitHub OIDC token subject (GitHub uses immutable IDs here, so renaming the repo does not break sign-in)."
}

variable "state_account_name" {
  type    = string
  default = "agamimtfdc3eee23"
}

variable "operator_object_id" {
  type        = string
  description = "Entra ID object ID of the person who runs Terraform locally (set via TF_VAR_operator_object_id)."
}
