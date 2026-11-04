# Oracle Cloud: one Always Free Ampere A1 VM (2 OCPU, 12 GB) hosts every OCI app in Docker,
# behind Caddy for automatic HTTPS, with Postgres on the same VM. Terraform builds the VM once;
# after that a small agent on the VM reads apps.yaml from GitHub every two minutes and
# brings the containers in line, so deploying an app never needs SSH or a VM rebuild.

terraform {
  required_version = ">= 1.12"
  required_providers {
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

locals {
  tags = { project = "30-apps-30-days", managed_by = "terraform" }
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
    ignore_changes = [source_details[0].source_id, metadata]
  }
}
