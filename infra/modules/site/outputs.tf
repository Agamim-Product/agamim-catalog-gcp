output "site_url" { value = "https://${local.domain}" }
output "dev_site_url" { value = "https://${local.dev_domain}" }
output "site_bucket" { value = google_storage_bucket.site.name }
output "dev_site_bucket" { value = google_storage_bucket.dev_site.name }
output "site_buckets" { value = local.site_buckets }
output "url_map" { value = google_compute_url_map.site.name }
output "ip_address" { value = google_compute_global_address.site.address }
output "notification_channel_ids" { value = [for c in google_monitoring_notification_channel.email : c.id] }
