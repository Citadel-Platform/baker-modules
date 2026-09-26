variable "api_max_instances" {
  type        = number
  default     = 5
  description = "The most instances the API scales to: a ceiling on cost."

  validation {
    condition     = var.api_max_instances >= 1 && var.api_max_instances <= 100
    error_message = "api_max_instances must be between 1 and 100."
  }
}

variable "api_allowed_origins" {
  type        = list(string)
  default     = []
  description = "Browser origins that may call the API. Empty means the project's own Firebase Hosting addresses."

  validation {
    condition     = alltrue([for o in var.api_allowed_origins : can(regex("^https://[a-z0-9.-]+(:[0-9]+)?$", o))])
    error_message = "Each origin is https://host, with no path and no wildcard."
  }
}

variable "api_secret_env" {
  type        = list(string)
  default     = []
  description = "Which of app_secrets the API reads, as environment variables."
}
