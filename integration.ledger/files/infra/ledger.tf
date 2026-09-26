# The ledger's Google Cloud side: where the Xero refresh token is kept, and
# expiry for connection links and the refresh lock.
#
# The Xero app's id and secret are application secrets (app.auto.tfvars.json).
# The refresh token is different: the API itself replaces it on every
# refresh, so the application's identity may add and destroy versions of
# this one secret, and of no other.

resource "google_secret_manager_secret" "xero_refresh" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-xero-refresh"
  labels    = local.app_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_iam_member" "xero_refresh" {
  for_each = toset([
    "roles/secretmanager.secretAccessor",
    "roles/secretmanager.secretVersionManager",
  ])

  project   = var.project_id
  secret_id = google_secret_manager_secret.xero_refresh.secret_id
  role      = each.value
  member    = "serviceAccount:${google_service_account.application.email}"
}

resource "google_firestore_field" "ledger_ttl" {
  for_each = toset(["_ledger_oauth_states", "_ledger_locks"])

  project    = var.project_id
  database   = "(default)"
  collection = each.value
  field      = "expireAt"

  ttl_config {}
  index_config {}
}

output "xero_redirect_uri" {
  description = "Add this as the redirect URI of the Xero app."
  value       = "${local.api_url}/v1/ledger/xero/callback"
}
