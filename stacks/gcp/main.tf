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

# Custom domains are not wired up on gcp yet. Fail the plan loudly instead of promising a URL
# (APP_URL) whose DNS and certificate nobody creates. TODO: see README "Custom domains".
# Cloud Run (needs a domain mapping and Google domain verification).
resource "terraform_data" "domain_unsupported" {
  for_each = { for name, a in local.apps : name => a.domain if try(a.domain, null) != null }
  input    = each.value
  lifecycle {
    precondition {
      condition     = each.value == null
      error_message = "App ${each.key} sets domain ${each.value}, but custom domains are not supported on gcp yet. Set domain: null for this cloud (see README, Custom domains)."
    }
  }
}

locals {
  app_url = {
    for name, a in local.apps : name => (
      try(a.domain, null) != null
      ? "https://${a.domain}"
      : "https://${name}-${var.project_number}.${var.region}.run.app"
    )
  }
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
    origin = distinct([
      "https://${each.key}-${var.project_number}.${var.region}.run.app",
      local.app_url[each.key],
    ])
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
