# The web app on Cloud Run, behind Firebase Hosting.
#
# Terraform owns the service, its registry and its secrets; the deploy script
# only rolls out new images. That split is why the image below is ignored
# after creation: the running revision is the script's to change, and a plan
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
  for_each = toset([
    "secretmanager.googleapis.com",
    "firebasehosting.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
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

# One secret per name in var.web_secrets. Terraform creates the secret, never
# its value: a value in Terraform is a value in the state file. Values are
# added with scripts/secrets.sh, which reads them from standard input.
resource "google_secret_manager_secret" "web" {
  for_each = toset(var.web_secrets)

  project   = var.project_id
  secret_id = "${local.web_name}-${lower(replace(each.value, "_", "-"))}"
  labels    = local.web_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.web]
}

# Only the application's own identity may read them.
resource "google_secret_manager_secret_iam_member" "web" {
  for_each = google_secret_manager_secret.web

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.application.email}"
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

      dynamic "env" {
        for_each = google_secret_manager_secret.web
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value.secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [google_secret_manager_secret_iam_member.web]
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

output "web_secret_ids" {
  value = { for k, s in google_secret_manager_secret.web : k => s.secret_id }
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
