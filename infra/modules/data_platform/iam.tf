# One service account per workload, each with only what it needs.

resource "google_service_account" "workload" {
  for_each     = local.workloads
  project      = var.project_id
  account_id   = "catalog-${each.key}-${var.env}"
  display_name = "Catalog ${each.key} (${var.env})"
  description  = each.value
}

locals {
  sa = { for k, v in google_service_account.workload : k => "serviceAccount:${v.email}" }
}

# ---- ingest: writes raw files (and its small state file) to the lake, nothing else ----
resource "google_storage_bucket_iam_member" "ingest_write" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = local.sa.ingest
}

# ---- transform (Dataform): reads bronze through BigLake, writes silver/gold/assertions ----
resource "google_project_iam_member" "transform_jobs" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = local.sa.transform
}

resource "google_bigquery_dataset_iam_member" "transform_read_bronze" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.layer["bronze"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = local.sa.transform
}

resource "google_bigquery_dataset_iam_member" "transform_write" {
  for_each   = toset(["silver", "gold", "assertions"])
  project    = var.project_id
  dataset_id = google_bigquery_dataset.layer[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = local.sa.transform
}

resource "google_bigquery_connection_iam_member" "transform_use_lake" {
  project       = var.project_id
  location      = var.region
  connection_id = google_bigquery_connection.lake.connection_id
  role          = "roles/bigquery.connectionUser"
  member        = local.sa.transform
}

# ---- api: reads gold only, plus the "gold is ready" marker in the lake ----
resource "google_project_iam_member" "api_jobs" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = local.sa.api
}

resource "google_bigquery_dataset_iam_member" "api_read_gold" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.layer["gold"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = local.sa.api
}

resource "google_storage_bucket_iam_member" "api_read_marker" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectViewer"
  member = local.sa.api
}

# ---- orchestrator (Workflows + Scheduler): runs the two jobs, writes the marker, logs ----
resource "google_cloud_run_v2_job_iam_member" "orchestrator_runs_jobs" {
  for_each = { ingest = google_cloud_run_v2_job.ingest.name, transform = google_cloud_run_v2_job.transform.name }
  project  = var.project_id
  location = var.region
  name     = each.value
  role     = "roles/run.developer" # includes running a job with environment overrides
  member   = local.sa.orchestrator
}

resource "google_project_iam_member" "orchestrator_project" {
  for_each = toset(["roles/run.viewer", "roles/logging.logWriter", "roles/workflows.invoker"])
  project  = var.project_id
  role     = each.value
  member   = local.sa.orchestrator
}

resource "google_storage_bucket_iam_member" "orchestrator_marker" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectUser" # create/overwrite the small _state/gold_ready.json marker
  member = local.sa.orchestrator
}
