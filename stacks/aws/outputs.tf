output "urls" {
  description = "Public URL of each app."
  value       = local.app_url
}

output "mirror_images" {
  description = "Images deploy/aws.sh copies from GHCR into ECR (source => destination)."
  value       = { for name, a in local.apps : "${a.image}:${a.tag}" => "${aws_ecr_repository.app[name].repository_url}:${a.tag}" }
}

output "custom_urls" {
  description = "Custom-domain URL of each app whose domain mapping exists (certificate issued)."
  value       = { for name, d in local.mapped_apps : name => "https://${d}" }
}

output "dns_records" {
  description = "DNS records per app with a domain. With `automatic` they are created in Cloudflare by this apply; otherwise add them by hand: `validation` proves ownership to ACM (add first), `final` points the app's domain at API Gateway (appears once the certificate is issued and deploy/aws.sh is rerun). Hosts are relative to the zone."
  value = {
    for name, d in local.domain_apps : name => {
      domain    = d
      automatic = var.manage_dns
      validation = {
        type  = "CNAME"
        host  = trimsuffix(trimsuffix(tolist(aws_acm_certificate.app[name].domain_validation_options)[0].resource_record_name, "."), ".${var.dns_zone}")
        name  = trimsuffix(tolist(aws_acm_certificate.app[name].domain_validation_options)[0].resource_record_name, ".")
        value = trimsuffix(tolist(aws_acm_certificate.app[name].domain_validation_options)[0].resource_record_value, ".")
      }
      final = contains(keys(local.mapped_apps), name) ? {
        type  = "CNAME"
        host  = trimsuffix(d, ".${var.dns_zone}")
        value = aws_apigatewayv2_domain_name.app[name].domain_name_configuration[0].target_domain_name
      } : null
    }
  }
}
