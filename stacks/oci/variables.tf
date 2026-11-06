variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  description = "Path to the API key file; CI writes the OCI_PRIVATE_KEY secret there for the run."
  type        = string
}

variable "region" {
  description = "Home region: Always Free resources exist only there."
  type        = string
}

variable "compartment_ocid" {
  type = string
}

variable "availability_domain_index" {
  description = "Ampere capacity is sometimes short in one availability domain. If creation fails with 'Out of host capacity', try 1 or 2."
  type        = number
  default     = 0
}

variable "catalog_url" {
  description = "Where the agent on the VM reads the app list."
  type        = string
  default     = "https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/apps.yaml"
}

variable "ssh_public_key" {
  description = "Optional: an SSH public key for debugging. Empty means no SSH access at all."
  type        = string
  default     = ""
}

variable "ssh_source_cidr" {
  description = "Where SSH is allowed from when a key is set."
  type        = string
  default     = "0.0.0.0/0"
}

variable "manage_dns" {
  description = "Create each OCI app's A record in Cloudflare. CI sets it when the CLOUDFLARE_API_TOKEN secret exists."
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
