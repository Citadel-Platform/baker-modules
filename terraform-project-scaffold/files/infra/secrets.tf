# The application's secrets: one Secret Manager secret per name in
# var.app_secrets, readable only by the application's service account. Each
# Cloud Run service mounts the ones it names (web_env_secrets, api_env_secrets).
#
# Declared in infra/app.auto.tfvars.json, which modules add to as they are
# bootstrapped: maps, so each module's entries merge beside the others'.
#
# Terraform creates a secret, never its value: a value in Terraform is a value
# in the state file. Values are set with scripts/secrets.sh, from standard
# input.

locals {
  app_labels = {
    application = var.name_prefix
    managed-by  = "terraform"
  }
}

resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_secret_manager_secret" "app" {
  for_each = var.app_secrets

  project   = var.project_id
  secret_id = "${var.name_prefix}-${lower(replace(each.key, "_", "-"))}"
  labels    = local.app_labels
  annotations = {
    purpose = each.value
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_iam_member" "app" {
  for_each = google_secret_manager_secret.app

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.application.email}"
}

output "app_secret_ids" {
  value = { for name, s in google_secret_manager_secret.app : name => s.secret_id }
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
