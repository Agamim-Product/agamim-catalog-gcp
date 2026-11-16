# Bronze lake (Cloud Storage), BigQuery datasets for bronze/silver/gold, and BigLake tables over the lake.

resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-raw-${var.env}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.env != "prod"
  labels                      = local.labels

  # Raw files are kept (gold can be rebuilt from them) but move to cheaper storage after 30 days.
  lifecycle_rule {
    condition {
      age                   = 30
      matches_storage_class = ["STANDARD"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.raw_retention_days > 0 ? [1] : []
    content {
      condition { age = var.raw_retention_days }
      action { type = "Delete" }
    }
  }
}

resource "google_bigquery_dataset" "layer" {
  for_each                   = local.datasets
  project                    = var.project_id
  dataset_id                 = each.value
  location                   = var.region
  description                = local.dataset_descriptions[each.key]
  delete_contents_on_destroy = var.env != "prod"
  labels                     = merge(local.labels, { layer = each.key })
}

# BigLake: BigQuery reads the raw files through this connection's own service account.
resource "google_bigquery_connection" "lake" {
  project       = var.project_id
  connection_id = "lake-${var.env}"
  location      = var.region
  friendly_name = "Bronze lake (${var.env})"
  cloud_resource {}
}

resource "google_storage_bucket_iam_member" "lake_read" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_bigquery_connection.lake.cloud_resource[0].service_account_id}"
}

locals {
  bronze_entities = {
    ckan_package   = { path = "package", description = "One line per dataset (CKAN package), unchanged." }
    ckan_datastore = { path = "datastore", description = "One line per table: columns, total and first rows." }
    ckan_records   = { path = "records", description = "One line per row of tables copied in full." }
    ckan_run       = { path = "run", description = "One line per ingest run, written last." }
  }
  bronze_schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "NULLABLE" },
    { name = "fetched_at", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "entity_id", type = "STRING", mode = "NULLABLE" },
    { name = "payload", type = "STRING", mode = "NULLABLE", description = "Source record as a JSON string" },
  ])
}

resource "google_bigquery_table" "bronze" {
  for_each            = local.bronze_entities
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.layer["bronze"].dataset_id
  table_id            = each.key
  description         = each.value.description
  deletion_protection = false # holds no data: it only points at files in the lake
  labels              = local.labels
  schema              = local.bronze_schema

  # BigQuery adds the partition columns dt and run to the stored schema, which would look like drift and
  # force a replacement on every apply. BigLake tables only accept the schema here, so changes to the four
  # base columns need a manual `terraform apply -replace=...` (the tables hold no data, so that is safe).
  lifecycle { ignore_changes = [schema] }

  external_data_configuration {
    source_format         = "NEWLINE_DELIMITED_JSON"
    autodetect            = false
    ignore_unknown_values = true
    connection_id         = google_bigquery_connection.lake.name
    source_uris           = ["gs://${google_storage_bucket.raw.name}/ckan/${each.value.path}/*"]

    hive_partitioning_options {
      mode                     = "CUSTOM"
      source_uri_prefix        = "gs://${google_storage_bucket.raw.name}/ckan/${each.value.path}/{dt:DATE}/{run:STRING}"
      require_partition_filter = false
    }
  }

  depends_on = [google_storage_bucket_iam_member.lake_read]
}
