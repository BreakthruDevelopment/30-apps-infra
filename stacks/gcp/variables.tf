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
