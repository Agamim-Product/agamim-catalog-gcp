variable "project_id" {
  type    = string
  default = "agamim-catalog-prod-il" # dev shares the prod project until the billing quota allows a second one
}

variable "region" {
  type    = string
  default = "me-west1"
}

variable "ckan_datasets" {
  type    = list(string)
  default = ["flydata"]
}

variable "schedule" {
  type    = string
  default = "*/30 * * * *"
}

variable "schedule_paused" {
  type    = bool
  default = false
}

variable "api_max_instances" {
  type    = number
  default = 3
}
