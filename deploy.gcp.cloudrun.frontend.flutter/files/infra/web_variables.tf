variable "web_max_instances" {
  type        = number
  default     = 3
  description = "The most instances the web app scales to: a ceiling on cost."

  validation {
    condition     = var.web_max_instances >= 1 && var.web_max_instances <= 100
    error_message = "web_max_instances must be between 1 and 100."
  }
}

variable "web_secrets" {
  type        = list(string)
  default     = []
  description = "Environment variables the server reads from Secret Manager, e.g. [\"STRIPE_KEY\"]. Values are set with scripts/secrets.sh."

  validation {
    condition     = alltrue([for s in var.web_secrets : can(regex("^[A-Z][A-Z0-9_]{0,40}$", s))])
    error_message = "Each web_secrets entry must be an upper-case environment variable name."
  }
}
