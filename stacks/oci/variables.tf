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
