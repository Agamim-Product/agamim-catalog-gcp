variable "project_id" { type = string }

variable "name" {
  type        = string
  description = "Short prefix for resource names, for example agamim-catalog"
}

variable "region" {
  type        = string
  description = "Bucket and serverless NEG location. Israel (Tel Aviv) is me-west1."
}

variable "domain" {
  type        = string
  default     = ""
  description = "Production host name. Empty uses a free <ip>.sslip.io name derived from the reserved IP."
}

variable "dev_domain" {
  type        = string
  default     = ""
  description = "Dev host name. Empty uses dev.<ip>.sslip.io."
}

variable "api_services" {
  type        = map(string)
  default     = {}
  description = "Cloud Run API service name per environment (keys: prod, dev). /api/* on that host is routed to it."

  validation {
    condition     = alltrue([for k in keys(var.api_services) : contains(["prod", "dev"], k)])
    error_message = "api_services keys must be prod or dev."
  }
}

variable "deployer_service_account" {
  type        = string
  description = "Email of the service account that releases the site (write access to the buckets)."
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Where uptime alerts are sent. Empty creates no notification channel."
}
