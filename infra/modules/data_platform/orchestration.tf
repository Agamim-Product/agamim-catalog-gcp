# Workflows runs ingest then transform; Cloud Scheduler starts it every 30 minutes.

resource "google_workflows_workflow" "refresh" {
  name                = "catalog-refresh-${var.env}"
  project             = var.project_id
  region              = var.region
  description         = "CKAN -> bronze -> Dataform (silver, gold) -> mark gold ready"
  service_account     = google_service_account.workload["orchestrator"].email
  call_log_level      = "LOG_ERRORS_ONLY"
  labels              = local.labels
  deletion_protection = false

  source_contents = templatefile("${path.module}/workflow.yaml.tftpl", {
    env           = var.env
    project       = var.project_id
    region        = var.region
    bucket        = google_storage_bucket.raw.name
    ready_marker  = local.ready_marker
    ingest_job    = google_cloud_run_v2_job.ingest.name
    transform_job = google_cloud_run_v2_job.transform.name
  })
}

resource "google_cloud_scheduler_job" "refresh" {
  name        = "catalog-refresh-${var.env}"
  project     = var.project_id
  region      = var.region
  description = "Starts catalog-refresh-${var.env}"
  schedule    = var.schedule
  time_zone   = "Asia/Jerusalem"
  paused      = var.schedule_paused

  retry_config { retry_count = 0 } # the next tick is the retry

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.refresh.id}/executions"
    body        = base64encode(jsonencode({ argument = "{}", callLogLevel = "LOG_ERRORS_ONLY" }))
    headers     = { "Content-Type" = "application/json" }

    oauth_token {
      service_account_email = google_service_account.workload["orchestrator"].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_project_iam_member.orchestrator_project]
}
