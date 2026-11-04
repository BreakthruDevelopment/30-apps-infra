output "urls" {
  description = "Public URL of each app."
  value       = local.app_url
}

output "default_hostnames" {
  description = "Cloud-assigned hostname of each app: the CNAME target for a custom domain."
  value       = { for name, app in azurerm_container_app.app : name => app.ingress[0].fqdn }
}

output "postgres_host" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}
