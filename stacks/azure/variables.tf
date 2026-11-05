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
