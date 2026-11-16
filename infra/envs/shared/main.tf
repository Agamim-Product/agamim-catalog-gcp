# Shared resources used by both environments: Google APIs, the container registry and the public load
# balancer with its two site buckets. dev and prod data platforms live in ../dev and ../prod.

locals {
  services = [
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "compute.googleapis.com",
    "dataform.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
    "workflowexecutions.googleapis.com",
    "workflows.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.services)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "catalog"
  format        = "DOCKER"
  description   = "Images for the catalog ingest job, transform job and API. Tagged by git commit."

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions { keep_count = 20 }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition { older_than = "2592000s" } # 30 days, unless kept above
  }

  depends_on = [google_project_service.enabled]
}

# CI pushes images; the deployer service account (used by GitHub Actions) needs write access.
resource "google_artifact_registry_repository_iam_member" "ci_push" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.ci_deployer_service_account}"
}

module "site" {
  source = "../../modules/site"

  project_id               = var.project_id
  name                     = "agamim-catalog"
  region                   = var.region
  domain                   = var.domain
  alert_email              = var.alert_email
  deployer_service_account = "gh-site-deployer@${var.project_id}.iam.gserviceaccount.com"
  api_services = {
    dev  = "catalog-api-dev"
    prod = "catalog-api-prod"
  }
}
