output "urls" {
  description = "Public URL of each app."
  value       = local.app_url
}

output "mirror_images" {
  description = "Images deploy/aws.sh copies from GHCR into ECR (source => destination)."
  value       = { for name, a in local.apps : "${a.image}:${a.tag}" => "${aws_ecr_repository.app[name].repository_url}:${a.tag}" }
}
