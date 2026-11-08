variable "project_id" {
  description = "Google Cloud project ID (repo variable GCP_PROJECT_ID)."
  type        = string
}

variable "project_number" {
  description = "Project number, used to build Cloud Run's deterministic URL (repo variable GCP_PROJECT_NUMBER)."
  type        = string
}

variable "region" {
  description = "Must be an always-free region: us-central1, us-east1 or us-west1."
  type        = string
  default     = "us-central1"
}

variable "max_instances" {
  description = "Upper bound on instances per app; 1 keeps every app inside the free tier."
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
  description = "Create each Google Cloud app's CNAME record in Cloudflare. CI sets it when the CLOUDFLARE_API_TOKEN secret exists."
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
