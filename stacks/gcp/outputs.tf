output "urls" {
  description = "Public run.app URL of each app (used by the health check; always valid)."
  value       = local.default_url
}

output "custom_urls" {
  description = "Custom URL of each app with a domain (the certificate may still be pending; see README)."
  value       = { for name, d in local.domain_apps : name => "https://${d}" }
}

output "custom_domain_ready" {
  description = "Whether each custom domain's mapping is Ready, i.e. APP_URL uses it."
  value       = local.domain_ready
}

output "mirror_images" {
  description = "Images CI copies from GHCR into Artifact Registry before deploying (source => destination)."
  value = merge(
    { (local.postgres_source) = local.postgres_image },
    { for name, a in local.apps : "${a.image}:${a.tag}" => "${local.registry}/${name}:${a.tag}" },
  )
}
