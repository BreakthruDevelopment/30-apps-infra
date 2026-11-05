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
  description = "The DNS zone kept at Network Solutions; used only to print host names relative to it."
  type        = string
  default     = "breakthruventures.ai"
}
