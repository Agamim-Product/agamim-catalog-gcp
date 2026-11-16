terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
  # The prefix is kept from the first setup (site only), so the existing load balancer stays in this state.
  backend "gcs" {
    bucket = "agamim-catalog-prod-il-tfstate"
    prefix = "prod/site"
  }
}

# Credentials come from the environment (ADC locally, Workload Identity Federation in CI).
provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}
