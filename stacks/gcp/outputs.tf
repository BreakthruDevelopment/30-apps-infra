output "urls" {
  description = "Public URL of each app."
  value       = local.app_url
}

output "mirror_images" {
  description = "Images CI copies from GHCR into Artifact Registry before deploying (source => destination)."
  value = merge(
    { (local.postgres_source) = local.postgres_image },
    { for name, a in local.apps : "${a.image}:${a.tag}" => "${local.registry}/${name}:${a.tag}" },
  )
}
