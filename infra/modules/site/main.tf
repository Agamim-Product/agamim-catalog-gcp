# Public site: Cloud Storage buckets -> backend buckets (Cloud CDN) -> one global external HTTPS load balancer.
# /api/* on each host goes to that environment's Cloud Run API through a serverless network endpoint group.
#
#   <ip>.sslip.io      -> prod site bucket, /api/* -> catalog-api-prod
#   dev.<ip>.sslip.io  -> dev site bucket,  /api/* -> catalog-api-dev
#
# Resource addresses of the original single-site setup are unchanged, so the existing state still applies.

locals {
  ip_host     = "${replace(google_compute_global_address.site.address, ".", "-")}.sslip.io"
  domain      = var.domain != "" ? var.domain : local.ip_host
  dev_domain  = var.dev_domain != "" ? var.dev_domain : "dev.${local.ip_host}"
  api_paths   = ["/api/*", "/healthz"]
  environment = { prod = local.domain, dev = local.dev_domain }
}

# ---------- Buckets ----------
resource "google_storage_bucket" "site" {
  name                        = "${var.project_id}-site"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning { enabled = true } # rollback = restore the previous generation

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "dev_site" {
  name                        = "${var.project_id}-site-dev"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true # dev only: holds nothing that cannot be rebuilt

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

locals {
  site_buckets = { prod = google_storage_bucket.site.name, dev = google_storage_bucket.dev_site.name }
}

# The CDN reads the buckets anonymously. The site is public by decision (open data, no login).
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.site.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "dev_public_read" {
  bucket = google_storage_bucket.dev_site.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "deployer_write" {
  bucket = google_storage_bucket.site.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.deployer_service_account}"
}

resource "google_storage_bucket_iam_member" "dev_deployer_write" {
  bucket = google_storage_bucket.dev_site.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.deployer_service_account}"
}

# rsync also needs to read bucket metadata (storage.buckets.get); objectAdmin does not include it.
resource "google_storage_bucket_iam_member" "deployer_bucket_read" {
  bucket = google_storage_bucket.site.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${var.deployer_service_account}"
}

resource "google_storage_bucket_iam_member" "dev_deployer_bucket_read" {
  bucket = google_storage_bucket.dev_site.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${var.deployer_service_account}"
}

# The deployer may only invalidate the CDN cache, nothing else on the load balancer.
resource "google_project_iam_custom_role" "cdn_invalidate" {
  project     = var.project_id
  role_id     = "cdnCacheInvalidator"
  title       = "CDN cache invalidator"
  description = "Invalidate Cloud CDN cache for the site URL map"
  permissions = ["compute.urlMaps.invalidateCache", "compute.urlMaps.get"]
}

resource "google_project_iam_member" "deployer_invalidate" {
  project = var.project_id
  role    = google_project_iam_custom_role.cdn_invalidate.id
  member  = "serviceAccount:${var.deployer_service_account}"
}

# ---------- Address, certificates ----------
resource "google_compute_global_address" "site" {
  name    = "${var.name}-ip"
  project = var.project_id
}

resource "google_compute_managed_ssl_certificate" "site" {
  name    = "${var.name}-cert"
  project = var.project_id
  managed { domains = [local.domain] }

  lifecycle { create_before_destroy = true }
}

# A second certificate for the dev host, so adding dev never re-issues the production certificate.
resource "google_compute_managed_ssl_certificate" "dev" {
  name    = "${var.name}-dev-cert"
  project = var.project_id
  managed { domains = [local.dev_domain] }

  lifecycle { create_before_destroy = true }
}

# Cloud Armor is not used: this account's security-policy quota is 0. Revisit with a quota increase.

# ---------- Backends ----------
resource "google_compute_backend_bucket" "site" {
  name             = "${var.name}-site"
  project          = var.project_id
  bucket_name      = google_storage_bucket.site.name
  enable_cdn       = true
  compression_mode = "AUTOMATIC"

  cdn_policy {
    cache_mode        = "USE_ORIGIN_HEADERS" # the release workflow sets Cache-Control per file type
    negative_caching  = true
    serve_while_stale = 86400
  }
}

resource "google_compute_backend_bucket" "dev_site" {
  name             = "${var.name}-site-dev"
  project          = var.project_id
  bucket_name      = google_storage_bucket.dev_site.name
  enable_cdn       = true
  compression_mode = "AUTOMATIC"

  cdn_policy {
    cache_mode       = "USE_ORIGIN_HEADERS"
    negative_caching = true
  }
}

resource "google_compute_region_network_endpoint_group" "api" {
  for_each              = var.api_services
  name                  = "${var.name}-api-${each.key}"
  project               = var.project_id
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run { service = each.value }
}

resource "google_compute_backend_service" "api" {
  for_each              = var.api_services
  name                  = "${var.name}-api-${each.key}"
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  enable_cdn            = true
  compression_mode      = "AUTOMATIC"

  backend { group = google_compute_region_network_endpoint_group.api[each.key].id }

  # The API sets Cache-Control on every response (5 minutes for catalog data, no-store for health).
  cdn_policy {
    cache_mode       = "USE_ORIGIN_HEADERS"
    negative_caching = false
    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# ---------- Load balancer ----------
resource "google_compute_url_map" "site" {
  name            = var.name
  project         = var.project_id
  default_service = google_compute_backend_bucket.site.id

  dynamic "host_rule" {
    for_each = local.environment
    content {
      hosts        = [host_rule.value]
      path_matcher = host_rule.key
    }
  }

  path_matcher {
    name            = "prod"
    default_service = google_compute_backend_bucket.site.id
    dynamic "path_rule" {
      for_each = contains(keys(var.api_services), "prod") ? [1] : []
      content {
        paths   = local.api_paths
        service = google_compute_backend_service.api["prod"].id
      }
    }
  }

  path_matcher {
    name            = "dev"
    default_service = google_compute_backend_bucket.dev_site.id
    dynamic "path_rule" {
      for_each = contains(keys(var.api_services), "dev") ? [1] : []
      content {
        paths   = local.api_paths
        service = google_compute_backend_service.api["dev"].id
      }
    }
  }
}

resource "google_compute_target_https_proxy" "site" {
  name    = "${var.name}-https"
  project = var.project_id
  url_map = google_compute_url_map.site.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.site.id,
    google_compute_managed_ssl_certificate.dev.id,
  ]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.name}-https"
  project               = var.project_id
  target                = google_compute_target_https_proxy.site.id
  ip_address            = google_compute_global_address.site.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# Port 80 only redirects to HTTPS.
resource "google_compute_url_map" "redirect" {
  name    = "${var.name}-redirect"
  project = var.project_id
  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "${var.name}-http"
  project = var.project_id
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http"
  project               = var.project_id
  target                = google_compute_target_http_proxy.redirect.id
  ip_address            = google_compute_global_address.site.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# ---------- Monitoring ----------
resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email == "" ? 0 : 1
  project      = var.project_id
  display_name = "Catalog alerts"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

resource "google_monitoring_uptime_check_config" "site" {
  project      = var.project_id
  display_name = "${var.name}-site"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path           = "/"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"
  }

  monitored_resource {
    type   = "uptime_url"
    labels = { project_id = var.project_id, host = local.domain }
  }
}

resource "google_monitoring_alert_policy" "down" {
  project      = var.project_id
  display_name = "Catalog site is down"
  combiner     = "OR"

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.site.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.project_id"]
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]
}
