output "raw_bucket" { value = google_storage_bucket.raw.name }
output "datasets" { value = local.datasets }
output "ingest_job" { value = google_cloud_run_v2_job.ingest.name }
output "transform_job" { value = google_cloud_run_v2_job.transform.name }
output "api_service" { value = google_cloud_run_v2_service.api.name }
output "workflow" { value = google_workflows_workflow.refresh.name }
output "service_accounts" { value = { for k, v in google_service_account.workload : k => v.email } }
