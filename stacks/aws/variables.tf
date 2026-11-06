variable "region" {
  description = "The only region this account's project guardrails allow."
  type        = string
  default     = "us-east-2"
}

variable "gemini_api_key" {
  description = "Gemini API key (free tier). Empty means apps that ask for Gemini fall back to demo answers."
  type        = string
  default     = ""
  sensitive   = true
}

variable "app_secrets" {
  description = "Per-app secret environment variables: app name => env var name => value. Only names listed in that app's `secrets:` in apps.yaml are applied; extras and missing values are ignored."
  type        = map(map(string))
  default     = {}
  sensitive   = true
}

variable "issued_domains" {
  description = "Custom domains whose ACM certificate is ISSUED. deploy/aws.sh fills this from `aws acm list-certificates`; a domain here gets its API Gateway domain mapping and APP_URL."
  type        = list(string)
  default     = []
}

variable "dns_zone" {
  description = "The DNS zone, hosted at Cloudflare. Terraform only creates records for app domains under it; it never manages the zone itself."
  type        = string
  default     = "breakthruventures.ai"
}

variable "manage_dns" {
  description = "Create each app's DNS records (ACM validation and the app CNAME) in Cloudflare. deploy/aws.sh sets it when a Cloudflare token is in Parameter Store; false keeps the manual two-phase flow."
  type        = bool
  default     = false
}

variable "cloudflare_zone_id" {
  description = "Zone ID of dns_zone (not secret; zone Overview page, API section). Empty means look it up by name, which needs Zone:Read on the token."
  type        = string
  default     = ""
}

variable "reserved_hosts" {
  description = "Names in the zone that belong to email, the website and other services. An app domain using one fails the plan."
  type        = list(string)
  default     = ["www", "dev", "strategy", "email", "mail", "mailo", "webmail", "autodiscover", "autoconfig", "imap", "pop", "pop3", "smtp", "ftp", "ns1", "ns2"]
}
