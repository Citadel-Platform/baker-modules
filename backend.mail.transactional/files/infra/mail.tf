# Mail's schedule: the sweep that dispatches messages whose task was never
# created and removes bodies past their retention. Everything else mail
# needs (the queue, the internal caller, its secrets and settings) is the
# API's and the scaffold's; mail adds its entries in app.auto.tfvars.json.

resource "google_cloud_scheduler_job" "mail_sweep" {
  project     = var.project_id
  region      = var.region
  name        = "${var.name_prefix}-mail-sweep"
  description = "Dispatches stranded mail and removes old bodies."
  schedule    = "*/5 * * * *"
  time_zone   = "Etc/UTC"

  # A sweep that did not run is simply run again next time; retrying one
  # would only overlap with the next.
  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "${local.api_url}/internal/mail/sweep"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode("{}")

    oidc_token {
      service_account_email = google_service_account.internal_caller.email
      audience              = local.api_oidc_audience
    }
  }

  depends_on = [google_project_service.api]
}

output "mail_webhook_url" {
  description = "Where Resend should send delivery events."
  value       = "${local.api_url}/webhooks/mail"
}
