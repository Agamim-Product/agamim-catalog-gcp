output "site_url" { value = module.site.site_url }
output "dev_site_url" { value = module.site.dev_site_url }
output "site_bucket" { value = module.site.site_bucket }
output "dev_site_bucket" { value = module.site.dev_site_bucket }
output "url_map" { value = module.site.url_map }
output "ip_address" { value = module.site.ip_address }
output "notification_channel_ids" { value = module.site.notification_channel_ids }
output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
