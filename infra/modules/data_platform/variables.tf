variable "project_id" { type = string }

variable "region" {
  type    = string
  default = "me-west1"
}

variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod."
  }
}

variable "ckan_base_url" {
  type    = string
  default = "https://data.gov.il"
}

variable "ckan_datasets" {
  type        = list(string)
  description = "CKAN dataset names to ingest. Empty ingests every public dataset (metadata only is advised then)."
}

variable "schedule" {
  type    = string
  default = "*/30 * * * *"
}

variable "schedule_paused" {
  type    = bool
  default = false
}

variable "raw_retention_days" {
  type        = number
  default     = 0
  description = "Delete raw files after this many days. 0 keeps them (they move to Nearline after 30 days)."
}

variable "api_max_instances" {
  type    = number
  default = 2
}

variable "notification_channel_ids" {
  type    = list(string)
  default = []
}

variable "placeholder_job_image" {
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/job:latest"
  description = "Image used only until the first deploy sets the real one."
}

variable "placeholder_service_image" {
  type    = string
  default = "us-docker.pkg.dev/cloudrun/container/hello:latest"
}
