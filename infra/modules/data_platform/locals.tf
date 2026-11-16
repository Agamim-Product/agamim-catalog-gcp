locals {
  labels = { app = "agamim-catalog", env = var.env }

  default_job_image = "us-docker.pkg.dev/cloudrun/container/job:latest"
  ready_marker      = "_state/gold_ready.json"

  datasets = {
    bronze     = "bronze_${var.env}"
    silver     = "silver_${var.env}"
    gold       = "gold_${var.env}"
    assertions = "assertions_${var.env}"
  }

  dataset_descriptions = {
    bronze     = "Bronze: BigLake tables over the raw lake (gs://${var.project_id}-raw-${var.env}). Read in place."
    silver     = "Silver: typed, de-duplicated copies of the latest run. Built by Dataform."
    gold       = "Gold: the warehouse. Dimension tables with full history (SCD2). The API reads only this."
    assertions = "Dataform data-quality checks. A failing check stops the run before gold."
  }

  workloads = {
    ingest       = "Cloud Run Job: copies CKAN into the bronze lake"
    transform    = "Cloud Run Job: runs Dataform (bronze -> silver -> gold)"
    api          = "Cloud Run service: read-only catalog API over gold"
    orchestrator = "Workflows and Cloud Scheduler: runs a refresh every 30 minutes"
  }
}
