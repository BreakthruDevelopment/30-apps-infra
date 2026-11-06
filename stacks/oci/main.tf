# Oracle Cloud: one Always Free Ampere A1 VM (2 OCPU, 12 GB) hosts every OCI app in Docker,
# behind Caddy for automatic HTTPS, with Postgres on the same VM. Terraform builds the VM once;
# after that a small agent on the VM reads apps.yaml from GitHub every two minutes and
# brings the containers in line, so deploying an app never needs SSH or a VM rebuild.

terraform {
  required_version = ">= 1.12"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0, < 9.0"
    }
  }
  # Filled in by -backend-config in CI (bucket, namespace, key, credentials).
  backend "oci" {}
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# DNS lives in Cloudflare. Only used when var.manage_dns is true (CI sets it when the
# CLOUDFLARE_API_TOKEN secret exists). Otherwise no cloudflare resource exists, so the placeholder is
# never sent anywhere. The real token comes from the CLOUDFLARE_API_TOKEN environment variable.
provider "cloudflare" {
  api_token = var.manage_dns ? null : "unused_dns_not_managed_00000000000000000" # 40 characters: the provider validates the format even when unused
}

locals {
  tags    = { project = "30-apps-30-days", managed_by = "terraform" }
  catalog = yamldecode(file("${path.module}/../../apps.yaml")).apps
  # DNS records Terraform owns: only apps on OCI in apps.yaml with a domain, and only with manage_dns.
  dns_apps = var.manage_dns ? { for a in local.catalog : a.name => a.domain if contains(a.clouds, "oci") && try(a.domain, null) != null } : {}
  zone_id  = var.cloudflare_zone_id != "" ? var.cloudflare_zone_id : try(data.cloudflare_zone.main[0].id, "")
}

data "cloudflare_zone" "main" {
  count = var.manage_dns && var.cloudflare_zone_id == "" ? 1 : 0
  # Needs Zone:Read on the token. With a DNS:Edit-only token set cloudflare_zone_id instead.
  filter = {
    name = var.dns_zone
  }
}

# Guard: Terraform may only create records under the app subdomains it is given; never the apex,
# mail, website or other existing names, and it never manages the zone itself.
resource "terraform_data" "dns_guard" {
  for_each = local.dns_apps
  input    = each.value
  lifecycle {
    precondition {
      condition     = endswith(each.value, ".${var.dns_zone}") && !contains(var.reserved_hosts, trimsuffix(each.value, ".${var.dns_zone}")) && !startswith(each.value, "_")
      error_message = "App ${each.key}: domain ${each.value} must be a subdomain of ${var.dns_zone} that is not a reserved name (${join(", ", var.reserved_hosts)})."
    }
  }
}

# The host's address for each OCI app's custom domain; Caddy on the VM gets the certificate itself.
resource "cloudflare_dns_record" "app" {
  for_each = local.dns_apps
  zone_id  = local.zone_id
  name     = each.value
  type     = "A"
  content  = oci_core_instance.host.public_ip
  ttl      = 1
  proxied  = false
  comment  = "30-apps-infra: ${each.key} on Oracle Cloud"

  depends_on = [terraform_data.dns_guard]
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# --- Network ----------------------------------------------------------------------------

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.20.0.0/16"]
  display_name   = "vcn-30apps"
  dns_label      = "apps30"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "igw-30apps"
  freeform_tags  = local.tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "rt-public"
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.main.id
  }
  freeform_tags = local.tags
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "sl-web"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  dynamic "ingress_security_rules" {
    for_each = toset(["80", "443"])
    content {
      source   = "0.0.0.0/0"
      protocol = "6" # TCP
      tcp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }

  # SSH only when a key is supplied (off by default; the agent means it's rarely needed).
  dynamic "ingress_security_rules" {
    for_each = var.ssh_public_key == "" ? [] : [1]
    content {
      source   = var.ssh_source_cidr
      protocol = "6"
      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  freeform_tags = local.tags
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = "10.20.1.0/24"
  display_name      = "subnet-public"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
  freeform_tags     = local.tags
}

# --- The host VM ------------------------------------------------------------------------

resource "oci_core_instance" "host" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = "apps-host"
  shape               = "VM.Standard.A1.Flex"
  freeform_tags       = local.tags

  # The whole Always Free Ampere allowance. Going over it disables every A1 VM in the tenancy.
  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = 100 # inside the 200 GB Always Free block storage
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = "apps-host"
  }

  metadata = merge(
    {
      user_data = base64encode(templatefile("${path.module}/files/cloud-init.yaml", {
        agent       = file("${path.module}/files/agent.py")
        catalog_url = var.catalog_url
      }))
    },
    var.ssh_public_key == "" ? {} : { ssh_authorized_keys = var.ssh_public_key },
  )

  lifecycle {
    # Newer Ubuntu images and cloud-init edits shouldn't rebuild the host (and its database).
    # To roll out an agent change, taint the instance deliberately.
    # availability_domain: the apply loop tries each AD for free capacity; an existing host must never be
    # rebuilt just because a different AD was tried this run.
    ignore_changes = [source_details[0].source_id, metadata, availability_domain]
  }
}
