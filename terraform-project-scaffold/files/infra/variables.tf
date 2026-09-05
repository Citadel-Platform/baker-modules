variable "project_id" {
  type        = string
  description = "The client's own Google Cloud project."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a lowercase Google Cloud project id."
  }
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Where the application's resources live."
}

variable "name_prefix" {
  type        = string
  description = "Prefixes every resource, so two applications in one project do not collide."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be lowercase and at most 21 characters."
  }
}
