# The web app on Cloud Run, behind Firebase Hosting.
#
# Terraform owns the service and its registry, and names the application
# secrets it reads (the scaffold owns those); the deploy script only rolls out
# new images. That split is why the image below is ignored after creation: the running revision is the script's to change, and a plan
# that tried to put the placeholder back would be a plan to take the site down.

locals {
  web_name = "${var.name_prefix}-web"
  web_labels = {
    application = var.name_prefix
    component   = "web"
    managed-by  = "terraform"
  }
}

resource "google_project_service" "web" {
  project            = var.project_id
  service            = "firebasehosting.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "web" {
  project       = var.project_id
  location      = var.region
  repository_id = local.web_name
  format        = "DOCKER"
  description   = "Images of the ${var.name_prefix} web app."
  labels        = local.web_labels

  # Old images are what a rollback deploys, so keep the recent ones.
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_service" "web" {
  project  = var.project_id
  name     = local.web_name
  location = var.region
  labels   = local.web_labels

  # Firebase Hosting calls the service from the internet.
  ingress = "INGRESS_TRAFFIC_ALL"

  # A Terraform-only guard: `terraform destroy` fails until it is set false and
  # applied. Deleting the site should take two deliberate steps.
  deletion_protection = true

  template {
    service_account = google_service_account.application.email
    labels          = local.web_labels

    scaling {
      min_instance_count = 0
      max_instance_count = var.web_max_instances
    }

    containers {
      # A placeholder until the first deploy; see the note at the top.
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

      # The application secrets this service reads, as environment
      # variables. Declared in app_secrets (the scaffold); named here.
      dynamic "env" {
        for_each = var.web_env_secrets
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
      condition     = alltrue([for s in values(var.web_env_secrets) : contains(keys(var.app_secrets), s)])
      error_message = "Every secret in web_env_secrets must be declared in app_secrets."
    }
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [google_secret_manager_secret_iam_member.app]
}

# Anyone may call the service: it is a public website, and Firebase Hosting's
# rewrite reaches it as an anonymous caller. What the app shows is decided by
# sign-in and by the database's rules, not by who can load the page.
resource "google_cloud_run_v2_service_iam_member" "web_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.web.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "web_service" {
  value = google_cloud_run_v2_service.web.name
}

output "web_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.web.repository_id}"
}
