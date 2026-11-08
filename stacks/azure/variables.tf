variable "subscription_id" {
  description = "Azure subscription ID (repo variable AZURE_SUBSCRIPTION_ID)."
  type        = string
}

variable "location" {
  description = "Region for the apps."
  type        = string
  default     = "eastus"
}

variable "pg_location" {
  description = "Region for Postgres. New subscriptions are sometimes blocked from a region for Flexible Server; change this if creation fails with a location restriction."
  type        = string
  default     = "centralus" # eastus, eastus2, westus2, southcentralus don't offer B1ms to this subscription
}

variable "pg_allowed_extensions" {
  description = "Postgres extensions apps may CREATE EXTENSION on the shared server (azure.extensions). Joined with commas and upper-cased. pgvector is VECTOR."
  type        = list(string)
  default     = ["VECTOR"]
}

variable "max_instances" {
  description = "Upper bound on replicas per app. Kept at 1 so nothing can grow past the free grant; raising it is the scale story."
  type        = number
  default     = 1
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

variable "manage_dns" {
  description = "Create each Azure app's CNAME and asuid TXT records in Cloudflare. CI sets it when the CLOUDFLARE_API_TOKEN secret exists."
  type        = bool
  default     = false
}

variable "cloudflare_zone_id" {
  description = "Zone ID of dns_zone (not secret; zone Overview page, API section). Empty means look it up by name, which needs Zone:Read on the token."
  type        = string
  default     = ""
}

variable "dns_zone" {
  description = "The DNS zone, hosted at Cloudflare. Terraform only creates records for app domains under it; it never manages the zone itself."
  type        = string
  default     = "breakthruventures.ai"
}

variable "reserved_hosts" {
  description = "Names in the zone that belong to email, the website and other services. An app domain using one fails the plan."
  type        = list(string)
  default     = ["www", "dev", "strategy", "email", "mail", "mailo", "webmail", "autodiscover", "autoconfig", "imap", "pop", "pop3", "smtp", "ftp", "ns1", "ns2"]
}
