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
