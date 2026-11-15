# The Build Tracker's sync (catalog refresh and health checks), run by Cloud Scheduler.
# GitHub's scheduled workflows were delayed by 3–5 hours, which left the tracker's board stale.
# One job: Cloud Scheduler's free tier is 3 jobs per billing account. The daily summaries stay on the GitHub
# workflow in ai-dev-os, where a delay doesn't matter.
#
# Off until the TRACKER_SYNC_TOKEN repository secret exists (the tracker's SYNC_TOKEN). The token is sent as a
# request header, so it is stored in the job and in Terraform state (the state bucket is private).

variable "tracker_sync_token" {
  description = "The Build Tracker's SYNC_TOKEN (repository secret TRACKER_SYNC_TOKEN). Empty means no scheduler job."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tracker_url" {
  description = "Base URL of the Build Tracker."
  type        = string
  default     = "https://app1.breakthruventures.ai"
}

locals {
  tracker_scheduler = var.tracker_sync_token != "" ? 1 : 0
}

# --- Cloud Cost Scaler (app 31): nightly price refresh ----------------------------------------------------
# A second job, `cost-scaler-refresh`, POSTs the app's /api/prices/refresh with the bearer token. The app
# refreshes one price source per call (aws_ec2, aws_other, azure, gcp, oci, footprint), so the job fires six
# times a night, ten minutes apart (07:05 to 07:55 UTC). Fires within one job are free: the free tier counts
# jobs (3 per billing account, shared with every project on it), not executions. With the tracker's job this
# makes 2 of 3.
#
# Created only when ALL of these hold, so it is off until Michael has entered the token and the app exists:
#   - the app `cost-scaler` is deployed to gcp in apps.yaml,
#   - it lists COST_SCALER_REFRESH_TOKEN under `secrets:`,
#   - the GitHub secret COST_SCALER_REFRESH_TOKEN has a value (CI then puts it in var.app_secrets).
# The token is sent as a request header, so it is stored in the job and in Terraform state (private bucket),
# like the tracker's. It is a sensitive value and never appears in plan output.
#
# The URL is the run.app one, which is always valid (the custom domain may be pending or absent).

variable "refresh_app" {
  description = "App whose /api/prices/refresh the nightly scheduler job calls."
  type        = string
  default     = "cost-scaler"
}

variable "refresh_token_name" {
  description = "Name of the app secret (env var) holding the refresh bearer token."
  type        = string
  default     = "COST_SCALER_REFRESH_TOKEN"
}

locals {
  # Names only (never values): derived from keys, like app_secret_names in main.tf.
  refresh_scheduler = contains(lookup(local.app_secret_names, var.refresh_app, []), var.refresh_token_name) ? 1 : 0
  refresh_url       = "${lookup(local.default_url, var.refresh_app, "")}/api/prices/refresh"
}

resource "google_project_service" "cloudscheduler" {
  count              = local.tracker_scheduler + local.refresh_scheduler > 0 ? 1 : 0
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_cloud_scheduler_job" "tracker_sync" {
  count       = local.tracker_scheduler
  name        = "build-tracker-sync"
  description = "POST /api/sync on the Build Tracker in pairs, twice an hour"
  region      = var.region
  # Pairs two minutes apart: the first call wakes scale-to-zero apps (Azure, Cloud Run), the second confirms.
  # The tracker marks an app down only after two failures within 10 minutes. Minutes avoid :00.
  schedule         = "15,17,45,47 * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "60s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
  }

  http_target {
    http_method = "POST"
    uri         = "${trimsuffix(var.tracker_url, "/")}/api/sync"
    headers = {
      Authorization  = "Bearer ${var.tracker_sync_token}"
      "Content-Type" = "application/json"
    }
    body = base64encode("{}")
  }

  depends_on = [google_project_service.cloudscheduler]
}

resource "google_cloud_scheduler_job" "cost_scaler_refresh" {
  count       = local.refresh_scheduler
  name        = "cost-scaler-refresh"
  description = "POST /api/prices/refresh on Cloud Cost Scaler: six fires a night, one price source per call"
  region      = var.region
  # Six sources, one per call, ten minutes apart, once a night (minutes avoid :00).
  schedule         = "5,15,25,35,45,55 7 * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "330s" # the service's timeout is 300 s; the app's own fetch deadline is 240 s

  # No retries: the next fire is 10 minutes away and the app picks the stalest source each time, so a retry
  # would only duplicate work (and the advisory lock makes overlap a no-op).
  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = local.refresh_url
    headers = {
      Authorization  = "Bearer ${var.app_secrets[var.refresh_app][var.refresh_token_name]}"
      "Content-Type" = "application/json"
    }
    body = base64encode("{}")
  }

  depends_on = [google_project_service.cloudscheduler]

  lifecycle {
    precondition {
      condition     = try(tonumber(trimsuffix(local.run_timeout[var.refresh_app], "s")) >= 240, false)
      error_message = "The ${var.refresh_app} refresh job needs the app's Cloud Run timeout to be at least 240s (the app's fetch deadline), but apps.yaml gives it ${try(local.run_timeout[var.refresh_app], "no timeout")}. Set `timeout: 300s` on the app."
    }
  }
}
