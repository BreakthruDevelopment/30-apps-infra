# Google Cloud: each app runs on Cloud Run (always-free in us-central1) and talks to
# Postgres on the always-free e2-micro VM over the private network (Direct VPC egress).
# The VM has no public IP; it pulls its Postgres image from Artifact Registry through
# Private Google Access, so nothing here needs an external address.

terraform {
  required_version = ">= 1.12"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.20, < 8.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Filled in by -backend-config in CI (bucket, prefix).
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# DNS lives in Cloudflare. Only used when var.manage_dns is true (CI sets it when the
# CLOUDFLARE_API_TOKEN secret exists). Otherwise no cloudflare resource exists, so the placeholder is
# never sent anywhere. The real token comes from the CLOUDFLARE_API_TOKEN environment variable.
provider "cloudflare" {
  api_token = var.manage_dns ? null : "unused_dns_not_managed_00000000000000000" # 40 characters: the provider validates the format even when unused
}

locals {
  catalog  = yamldecode(file("${path.module}/../../apps.yaml")).apps
  apps     = { for a in local.catalog : a.name => a if contains(a.clouds, "gcp") }
  registry = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}"
  labels   = { project = "30-apps-30-days", managed_by = "terraform" }

  # Postgres image, mirrored into Artifact Registry by CI (the VM can't reach Docker Hub).
  postgres_source = "docker.io/library/postgres:17-alpine"
  postgres_image  = "${local.registry}/postgres:17-alpine"
}

# --- Network ------------------------------------------------------------------------

resource "google_compute_network" "apps" {
  name                    = "apps"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "apps" {
  name                     = "apps-${var.region}"
  network                  = google_compute_network.apps.id
  region                   = var.region
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true
}

resource "google_compute_firewall" "postgres" {
  name          = "allow-postgres-internal"
  network       = google_compute_network.apps.id
  direction     = "INGRESS"
  source_ranges = [google_compute_subnetwork.apps.ip_cidr_range]
  target_tags   = ["postgres"]
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
}

# --- Images -----------------------------------------------------------------------------

resource "google_artifact_registry_repository" "apps" {
  repository_id = "apps"
  location      = var.region
  format        = "DOCKER"
  labels        = local.labels

  # Stay inside the 0.5 GB free storage: keep only the two newest versions of each image.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-two-newest"
    action = "KEEP"
    most_recent_versions {
      keep_count = 2
    }
  }
  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      older_than = "86400s"
    }
  }
}

# --- Postgres VM ------------------------------------------------------------------------

# The Compute default service account can already read this project's images, so the VM
# uses it; granting a dedicated account access would need IAM-admin rights the deploy
# identity deliberately doesn't have.
data "google_compute_default_service_account" "default" {}

resource "random_password" "pg" {
  length  = 32
  special = false
}

locals {
  databases = join(",", [for name in keys(local.apps) : replace(name, "-", "_")])
}

resource "google_compute_instance" "postgres" {
  name         = "postgres"
  machine_type = "e2-micro" # always-free in us-central1, us-east1, us-west1
  zone         = "${var.region}-a"
  tags         = ["postgres"]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
      size  = 30            # always-free allowance
      type  = "pd-standard" # always-free disk type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.apps.id
    # No access_config block: no public IP.
  }

  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Changing the database list updates metadata in place; a timer on the VM creates new databases.
    app-databases = local.databases
    user-data = templatefile("${path.module}/files/postgres-cloud-init.yaml", {
      image    = local.postgres_image
      registry = "${var.region}-docker.pkg.dev"
      password = random_password.pg.result
    })
  }

  allow_stopping_for_update = true

  lifecycle {
    # The image changes as Google publishes new COS builds; don't recreate the database VM for that.
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }

}

# --- Cloud Run apps -----------------------------------------------------------------------

resource "google_service_account" "run" {
  account_id   = "cloud-run-apps"
  display_name = "Cloud Run apps (no extra permissions)"
}

resource "random_password" "auth" {
  for_each = local.apps
  length   = 48
  special  = false
}

# --- Custom domains (Cloud Run domain mapping + Cloudflare DNS) ----------------------------------
# For an app with a domain, one apply creates:
#   1. google_cloud_run_domain_mapping (free, no load balancer; Preview in Google Cloud). The deploy
#      identity must be a verified owner of the domain in Search Console (done once, by hand).
#   2. A Cloudflare CNAME <domain> -> ghs.googlehosted.com (from the mapping's resource_records), DNS only so
#      Google sees its own host when it issues the managed certificate (15 minutes to 24 hours).
# APP_URL stays on the run.app URL until the mapping's Ready condition is True in state, so sign-in never
# breaks while the certificate is pending. Rerun the workflow (workflow_dispatch) after the certificate is
# issued: the refresh sees Ready and the next plan switches APP_URL.

locals {
  default_url = { for name, a in local.apps : name => "https://${name}-${var.project_number}.${var.region}.run.app" }
  domain_apps = { for name, a in local.apps : name => a.domain if try(a.domain, null) != null }
  # DNS records Terraform owns: only apps on gcp in apps.yaml with a domain, and only with manage_dns.
  dns_apps = var.manage_dns ? local.domain_apps : {}
  zone_id  = var.cloudflare_zone_id != "" ? var.cloudflare_zone_id : try(data.cloudflare_zone.main[0].id, "")

  # True only when state says the mapping is Ready. Unknown (just created) or missing counts as not ready, so
  # the apply that creates the mapping keeps the run.app URL. The mapping never references the service (it
  # names it as a string), so the service may read the mapping's status without a dependency cycle. Once Ready
  # is True it stays True, so there is no perpetual diff.
  domain_ready = {
    for name, d in local.domain_apps : name => try(
      anytrue([for c in google_cloud_run_domain_mapping.app[name].status[0].conditions : c.type == "Ready" && c.status == "True"]),
      false,
    )
  }

  app_url = {
    for name, a in local.apps : name => (
      lookup(local.domain_ready, name, false) ? "https://${local.domain_apps[name]}" : local.default_url[name]
    )
  }
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
  for_each = local.domain_apps
  input    = each.value

  # Without the Cloudflare token the CNAME can't be created, so the certificate would never be issued.
  # Fail the plan instead of half-applying.
  lifecycle {
    precondition {
      condition     = var.manage_dns
      error_message = "App ${each.key} has domain ${each.value}, but no Cloudflare token reached this run (manage_dns is false). Add the CLOUDFLARE_API_TOKEN secret (and CLOUDFLARE_ZONE_ID variable) to the production environment, or set domain: null."
    }
    precondition {
      condition     = endswith(each.value, ".${var.dns_zone}") && !contains(var.reserved_hosts, trimsuffix(each.value, ".${var.dns_zone}")) && !startswith(each.value, "_")
      error_message = "App ${each.key}: domain ${each.value} must be a subdomain of ${var.dns_zone} that is not a reserved name (${join(", ", var.reserved_hosts)})."
    }
  }
}

resource "google_cloud_run_domain_mapping" "app" {
  for_each = local.domain_apps
  location = var.region
  name     = each.value

  metadata {
    namespace = var.project_id
  }

  spec {
    # The service's name as a plain string, not a reference: the service reads this mapping's status for
    # APP_URL, so a reference back would be a cycle.
    route_name       = each.key
    certificate_mode = "AUTOMATIC"
  }

  depends_on = [terraform_data.dns_guard]

  lifecycle {
    # Google adds annotations and labels of its own.
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "cloudflare_dns_record" "cname" {
  for_each = local.dns_apps
  zone_id  = local.zone_id
  name     = each.value
  type     = "CNAME"
  # Google returns "ghs.googlehosted.com." (trailing dot); Cloudflare stores it without.
  content = trimsuffix([for r in google_cloud_run_domain_mapping.app[each.key].status[0].resource_records : r.rrdata if r.type == "CNAME"][0], ".")
  ttl     = 1
  proxied = false # Google must see its own host to issue the certificate
  comment = "30-apps-infra: ${each.key} on Cloud Run"
}

resource "google_cloud_run_v2_service" "app" {
  for_each            = local.apps
  name                = each.key
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = local.labels

  template {
    service_account                  = google_service_account.run.email
    max_instance_request_concurrency = 40
    timeout                          = "30s"

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = google_compute_network.apps.id
        subnetwork = google_compute_subnetwork.apps.id
      }
    }

    containers {
      image = "${local.registry}/${each.key}:${each.value.tag}"

      ports {
        container_port = 3000
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true # billed only while handling requests
        startup_cpu_boost = false
      }

      env {
        name = "DATABASE_URL"
        value = format("postgres://postgres:%s@%s:5432/%s",
          random_password.pg.result,
          google_compute_instance.postgres.network_interface[0].network_ip,
          replace(each.key, "-", "_"),
        )
      }
      env {
        name  = "BETTER_AUTH_SECRET"
        value = random_password.auth[each.key].result
      }
      env {
        name  = "APP_URL"
        value = local.app_url[each.key]
      }
      env {
        name  = "APP_NAME"
        value = try(each.value.title, each.key)
      }
      env {
        name  = "APP_VERSION"
        value = each.value.tag
      }
      env {
        name  = "CLOUD"
        value = "gcp"
      }
      env {
        name  = "MIGRATE_ON_START"
        value = "true"
      }
      env {
        name  = "AI_PROVIDER"
        value = local.ai_provider[each.key]
      }
      env {
        name  = "DB_POOL_MAX"
        value = "3"
      }
      dynamic "env" {
        for_each = contains(keys(local.storage_apps), each.key) ? toset(["STORAGE_BUCKET", "UPLOAD_BUCKET"]) : toset([])
        content {
          name  = env.value
          value = google_storage_bucket.uploads[each.key].name
        }
      }
      dynamic "env" {
        for_each = toset(local.app_secret_names[each.key])
        content {
          name  = env.value
          value = var.app_secrets[each.key][env.value]
        }
      }
      dynamic "env" {
        for_each = contains(local.gemini_apps, each.key) ? [1] : []
        content {
          name  = "GEMINI_API_KEY"
          value = var.gemini_api_key
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = google_cloud_run_v2_service.app
  name     = each.value.name
  location = each.value.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

locals {
  # An app that asks for Gemini runs on demo answers until the key is configured; the app
  # refuses to start with AI_PROVIDER=gemini and no key.
  ai_provider = { for name, a in local.apps : name => (
    try(a.ai, "demo") == "gemini" && var.gemini_api_key == "" ? "demo" : try(a.ai, "demo")
  ) }
  gemini_apps = toset([for name, p in local.ai_provider : name if p == "gemini"])
}

locals {
  # Names (never values) of the secrets each app declared in apps.yaml and that were supplied.
  app_secret_names = { for name, a in local.apps : name => [
    for v in try(a.secrets, []) : v if contains(nonsensitive(keys(try(var.app_secrets[name], {}))), v)
  ] }
}

# --- Private upload buckets (opt-in: `storage: true` in apps.yaml) ---------------------------
# One bucket per app, in the stack region (us-central1 regional storage is in the always-free 5 GB).
# Objects are never public: uniform bucket-level access, public access prevention enforced, and the
# app hands browsers short-lived V4 signed URLs. Signing uses IAM signBlob as the run service account
# (no keys); that account's tokenCreator-on-itself binding is made by bootstrap/gcp.sh, because the
# deploy identity cannot set service-account IAM policies.

locals {
  storage_apps = { for name, a in local.apps : name => a if try(a.storage, false) }
}

resource "google_storage_bucket" "uploads" {
  for_each      = local.storage_apps
  name          = "${var.project_id}-${each.key}-uploads"
  location      = var.region
  storage_class = "STANDARD"
  labels        = local.labels
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = false
  }

  # Soft-deleted bytes are billed, so keep none.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age            = 90
      matches_prefix = ["u/"]
    }
  }

  # Browsers PUT directly to the bucket from the app's own origin(s) only.
  cors {
    # Static, so the bucket never waits on the domain mapping; the custom origin only for apps with a domain.
    origin = concat(
      [local.default_url[each.key]],
      try(each.value.domain, null) != null ? ["https://${each.value.domain}"] : [],
    )
    method          = ["PUT"]
    response_header = ["Content-Type", "x-goog-content-length-range"]
    max_age_seconds = 3600
  }
}

# Object access for this app's service account, on this bucket only (no project-level storage role).
resource "google_storage_bucket_iam_member" "uploads_run" {
  for_each = local.storage_apps
  bucket   = google_storage_bucket.uploads[each.key].name
  role     = "roles/storage.objectUser"
  member   = "serviceAccount:${google_service_account.run.email}"
}
