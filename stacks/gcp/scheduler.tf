# The Build Tracker's half-hourly sync (catalog refresh and health checks), run by Cloud Scheduler.
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

resource "google_project_service" "cloudscheduler" {
  count              = local.tracker_scheduler
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_cloud_scheduler_job" "tracker_sync" {
  count       = local.tracker_scheduler
  name        = "build-tracker-sync"
  description = "POST /api/sync on the Build Tracker every 30 minutes"
  region      = var.region
  # Minutes avoid :00, when schedulers are busiest; the same minutes the GitHub workflow used.
  schedule         = "17,47 * * * *"
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
