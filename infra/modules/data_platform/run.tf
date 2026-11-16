# Cloud Run: two jobs (ingest, transform) and the read-only API.
# Terraform creates them with a placeholder image; the deploy pipeline sets the real image by digest,
# so the image fields are ignored here.

resource "google_cloud_run_v2_job" "ingest" {
  name                = "catalog-ingest-${var.env}"
  project             = var.project_id
  location            = var.region
  deletion_protection = false
  labels              = local.labels

  template {
    task_count = 1
    template {
      service_account = google_service_account.workload["ingest"].email
      timeout         = "1800s"
      max_retries     = 1
      containers {
        image   = var.placeholder_job_image
        command = var.placeholder_job_image == local.default_job_image ? null : ["catalog-ingest"]
        resources {
          limits = { cpu = "1", memory = "1Gi" }
        }
        env {
          name  = "BRONZE_URI"
          value = "gs://${google_storage_bucket.raw.name}"
        }
        env {
          name  = "CKAN_BASE_URL"
          value = var.ckan_base_url
        }
        env {
          name  = "CKAN_DATASETS"
          value = join(",", var.ckan_datasets)
        }
        env {
          name  = "FULL_ROWS"
          value = "true"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      template[0].template[0].containers[0].command,
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_job" "transform" {
  name                = "catalog-transform-${var.env}"
  project             = var.project_id
  location            = var.region
  deletion_protection = false
  labels              = local.labels

  template {
    task_count = 1
    template {
      service_account = google_service_account.workload["transform"].email
      timeout         = "1800s"
      max_retries     = 0 # Dataform retries failed actions itself; a whole re-run is the orchestrator's call
      containers {
        image = var.placeholder_job_image
        resources {
          limits = { cpu = "1", memory = "1Gi" }
        }
        env {
          name  = "DATAFORM_ENV"
          value = var.env
        }
        env {
          name  = "GCP_PROJECT"
          value = var.project_id
        }
        env {
          name  = "BQ_LOCATION"
          value = var.region
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].template[0].containers[0].image, client, client_version]
  }
}

resource "google_cloud_run_v2_service" "api" {
  name                = "catalog-api-${var.env}"
  project             = var.project_id
  location            = var.region
  deletion_protection = false
  labels              = local.labels
  # Reachable only through the load balancer, never on its run.app URL.
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account                  = google_service_account.workload["api"].email
    max_instance_request_concurrency = 80
    scaling {
      min_instance_count = 0
      max_instance_count = var.api_max_instances
    }
    containers {
      image = var.placeholder_service_image
      resources {
        limits            = { cpu = "1", memory = "512Mi" }
        cpu_idle          = true
        startup_cpu_boost = true
      }
      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOLD_DATASET"
        value = google_bigquery_dataset.layer["gold"].dataset_id
      }
      env {
        name  = "BQ_LOCATION"
        value = var.region
      }
      env {
        name  = "READY_MARKER_URI"
        value = "gs://${google_storage_bucket.raw.name}/${local.ready_marker}"
      }
      env {
        name  = "CATALOG_ENV"
        value = var.env
      }
    }
  }

  lifecycle {
    # scaling: the service-level block the API fills in by default (instance limits are set per revision above).
    ignore_changes = [template[0].containers[0].image, client, client_version, scaling]
  }
}

# The load balancer calls the API anonymously; the service is public by decision (open data, read-only).
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
