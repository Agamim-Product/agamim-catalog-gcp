# Data platform for the prod environment: bronze lake, BigQuery layers, jobs, API, orchestration.
data "terraform_remote_state" "shared" {
  backend = "gcs"
  config = {
    bucket = "agamim-catalog-prod-il-tfstate"
    prefix = "prod/site"
  }
}

module "platform" {
  source = "../../modules/data_platform"

  project_id               = var.project_id
  region                   = var.region
  env                      = "prod"
  ckan_datasets            = var.ckan_datasets
  schedule                 = var.schedule
  schedule_paused          = var.schedule_paused
  api_max_instances        = var.api_max_instances
  notification_channel_ids = try(data.terraform_remote_state.shared.outputs.notification_channel_ids, [])
}
