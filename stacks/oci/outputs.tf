output "public_ip" {
  description = "The host's public IP: the A record target for any OCI app's custom domain."
  value       = oci_core_instance.host.public_ip
}

output "default_url_pattern" {
  description = "Apps without a custom domain are served at https://<app>.<ip-with-dashes>.sslip.io."
  value       = "https://<app>.${replace(oci_core_instance.host.public_ip, ".", "-")}.sslip.io"
}
