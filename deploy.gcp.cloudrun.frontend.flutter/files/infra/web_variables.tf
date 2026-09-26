variable "web_max_instances" {
  type        = number
  default     = 3
  description = "The most instances the web app scales to: a ceiling on cost."

  validation {
    condition     = var.web_max_instances >= 1 && var.web_max_instances <= 100
    error_message = "web_max_instances must be between 1 and 100."
  }
}

variable "web_env_secrets" {
  type        = map(string)
  default     = {}
  description = "Environment variables the web server reads from application secrets: variable name to app_secrets name."
}
