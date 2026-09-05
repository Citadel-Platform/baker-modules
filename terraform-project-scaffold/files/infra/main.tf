# A client's own Google Cloud project, as far as their application needs it.
#
# Deliberately small. This is the scaffold an application is deployed onto, not
# Citadel's own infrastructure: the platform builds the client's data plane,
# their Exigence runtime and their Devstation through reviewed templates that
# live in the provisioner image. What is here is what the client's own
# application needs and nothing else.

terraform {
  required_version = ">= 1.14"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enabled before anything tries to call them. A service a template uses and
# never enables fails partway through an apply, on a project that has never
# had a reason for it -- which is invisible to every existing client and fatal
# to the next one.
resource "google_project_service" "required" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "firestore.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# What the application runs as. No roles are granted here: what an application
# may do is decided per client, and a scaffold that guessed would guess wide.
resource "google_service_account" "application" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-app"
  display_name = "${var.name_prefix} application"
  description  = "The identity this client's application runs as."

  depends_on = [google_project_service.required]
}

output "service_account_email" {
  value = google_service_account.application.email
}
