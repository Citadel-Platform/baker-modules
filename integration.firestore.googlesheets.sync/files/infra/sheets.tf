# Sheets sync's Google Cloud side: a Firestore trigger per synced collection,
# the nightly reconcile, and expiry for the sync's locks and replay records.
#
# The synced collections are named once, in app.auto.tfvars.json as
# api_env.SHEETS_COLLECTIONS ("students,invoices"): the API reads the same
# value, and the reconcile reports any mapping it does not cover.

locals {
  sheets_collections = compact(split(",", lookup(var.api_env, "SHEETS_COLLECTIONS", "")))
}

resource "google_project_service" "sheets" {
  for_each = toset([
    "eventarc.googleapis.com",
    "sheets.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# The trigger delivers as the internal caller, which may receive events.
resource "google_project_iam_member" "sheets_event_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.internal_caller.email}"
}

# One trigger per collection, for its top-level documents only. It sends
# the event to the API, which reads the document path from the event's
# subject and queues a sync; the event body is not used.
resource "google_eventarc_trigger" "sheets" {
  for_each = toset(local.sheets_collections)

  project  = var.project_id
  name     = "${var.name_prefix}-sheets-${lower(replace(each.value, "_", "-"))}"
  location = var.firestore_location
  labels   = local.api_labels

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.firestore.document.v1.written"
  }
  matching_criteria {
    attribute = "database"
    value     = "(default)"
  }
  matching_criteria {
    attribute = "document"
    value     = "${each.value}/{id}"
    operator  = "match-path-pattern"
  }

  event_data_content_type = "application/protobuf"
  service_account         = google_service_account.internal_caller.email

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.api.name
      region  = var.region
      path    = "/internal/sheets/changed"
    }
  }

  depends_on = [
    google_project_service.sheets,
    google_project_iam_member.sheets_event_receiver,
  ]
}

resource "google_cloud_scheduler_job" "sheets_reconcile" {
  project     = var.project_id
  region      = var.region
  name        = "${var.name_prefix}-sheets-reconcile"
  description = "Repairs drift between synced collections and their tabs."
  schedule    = "0 3 * * *"
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "${local.api_url}/internal/sheets/reconcile"
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

# Locks and replay records delete themselves.
resource "google_firestore_field" "sheets_ttl" {
  for_each = toset(["_sheets_locks", "_sheets_nonces"])

  project    = var.project_id
  database   = "(default)"
  collection = each.value
  field      = "expireAt"

  ttl_config {}
  index_config {}
}

output "sheets_webhook_url" {
  description = "API_URL for the spreadsheet's Apps Script is api_url; this is the route it posts to."
  value       = "${local.api_url}/webhooks/sheets"
}
