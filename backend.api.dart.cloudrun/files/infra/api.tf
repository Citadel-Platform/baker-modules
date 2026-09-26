# The application's API on Cloud Run.
#
# Terraform owns the service, its registry and what it may do; the deploy
# script only rolls out images (see web.tf's note on the ignored image).

locals {
  api_name = "${var.name_prefix}-api"
  api_labels = {
    application = var.name_prefix
    component   = "api"
    managed-by  = "terraform"
  }
  # Browsers may call the API from the app's own Firebase Hosting addresses
  # unless told otherwise.
  api_origins = length(var.api_allowed_origins) > 0 ? var.api_allowed_origins : [
    "https://${var.project_id}.web.app",
    "https://${var.project_id}.firebaseapp.com",
  ]
  # What Cloud Tasks and Scheduler put in their tokens' audience, and what the
  # API accepts. Any fixed string both sides agree on.
  api_oidc_audience = "${local.api_name}-internal"

  # The service's own address, which tasks call back. Cloud Run's
  # deterministic form, so it is known before the service exists and the
  # service can be told it.
  api_url = "https://${local.api_name}-${data.google_project.this.number}.${var.region}.run.app"
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "api" {
  for_each = toset([
    "cloudtasks.googleapis.com",
    "cloudscheduler.googleapis.com",
    "identitytoolkit.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Work the API hands to itself: mail to send, records to sync. Retried with
# backoff until the route answers 2xx, then dropped after the last attempt
# (the feature's own sweep finds what was never finished).
resource "google_cloud_tasks_queue" "work" {
  project  = var.project_id
  name     = "${local.api_name}-work"
  location = var.region

  rate_limits {
    max_dispatches_per_second = 10
    max_concurrent_dispatches = 20
  }

  retry_config {
    max_attempts  = 10
    min_backoff   = "10s"
    max_backoff   = "3600s"
    max_doublings = 6
  }

  depends_on = [google_project_service.api]
}

# The application queues tasks, and the tasks carry tokens for the internal
# caller, which the application must be allowed to issue.
resource "google_cloud_tasks_queue_iam_member" "work_enqueue" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.work.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.application.email}"
}

resource "google_service_account_iam_member" "act_as_internal" {
  service_account_id = google_service_account.internal_caller.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.application.email}"
}

resource "google_artifact_registry_repository" "api" {
  project       = var.project_id
  location      = var.region
  repository_id = local.api_name
  format        = "DOCKER"
  description   = "Images of the ${var.name_prefix} API."
  labels        = local.api_labels

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }

  depends_on = [google_project_service.required]
}

# What the application's identity needs for the API itself: its data, and
# looking people up to check a sign-in was not revoked. Nothing wider.
resource "google_project_iam_member" "api" {
  for_each = toset([
    "roles/datastore.user",
    "roles/firebaseauth.viewer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.application.email}"
}

# The identity Cloud Tasks and Cloud Scheduler call internal routes as.
# Separate from the application's, so a route open to it is open to the
# platform's own jobs and nothing else.
resource "google_service_account" "internal_caller" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-internal"
  display_name = "${var.name_prefix} internal caller"
  description  = "Cloud Tasks and Scheduler call the API's internal routes as this."
}

# Idempotency records delete themselves after their expireAt.
resource "google_firestore_field" "idempotency_ttl" {
  project    = var.project_id
  database   = "(default)"
  collection = "_idempotency"
  field      = "expireAt"

  ttl_config {}

  # Only the TTL: no single-field indexes on a collection only read by id.
  index_config {}
}

resource "google_cloud_run_v2_service" "api" {
  project  = var.project_id
  name     = local.api_name
  location = var.region
  labels   = local.api_labels
  ingress  = "INGRESS_TRAFFIC_ALL"

  deletion_protection = true

  template {
    service_account = google_service_account.application.email
    labels          = local.api_labels

    scaling {
      min_instance_count = 0
      max_instance_count = var.api_max_instances
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      startup_probe {
        http_get {
          path = "/healthz"
        }
        period_seconds    = 2
        failure_threshold = 10
      }

      env {
        name  = "FIREBASE_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "ALLOWED_ORIGINS"
        value = join(",", local.api_origins)
      }
      env {
        name  = "OIDC_AUDIENCE"
        value = local.api_oidc_audience
      }
      env {
        name  = "INTERNAL_CALLER"
        value = google_service_account.internal_caller.email
      }
      env {
        name  = "TASKS_QUEUE"
        value = google_cloud_tasks_queue.work.id
      }
      env {
        name  = "API_URL"
        value = local.api_url
      }

      # Plain settings other modules add (MAIL_FROM, …), then secrets.
      dynamic "env" {
        for_each = var.api_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.api_env_secrets
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.app[env.value].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = alltrue([for s in values(var.api_env_secrets) : contains(keys(var.app_secrets), s)])
      error_message = "Every secret in api_env_secrets must be declared in app_secrets."
    }
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.app,
    google_project_iam_member.api,
    google_cloud_tasks_queue_iam_member.work_enqueue,
    google_service_account_iam_member.act_as_internal,
  ]
}

# Browsers call the API directly, so anyone may reach it; every route decides
# for itself who it answers (ApiAccess), and refuses by default.
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "api_service" {
  value = google_cloud_run_v2_service.api.name
}

output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "api_url_deterministic" {
  description = "The address tasks call. Should equal api_url; if not, tasks cannot reach the API."
  value       = local.api_url
}

output "api_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.api.repository_id}"
}

output "internal_caller" {
  value = google_service_account.internal_caller.email
}

output "api_oidc_audience" {
  value = local.api_oidc_audience
}
