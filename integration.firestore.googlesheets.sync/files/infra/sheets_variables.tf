variable "firestore_location" {
  type        = string
  description = "Where the (default) Firestore database is (e.g. nam5, asia-southeast1): Firestore triggers must be created there."

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.firestore_location))
    error_message = "firestore_location is a location id such as nam5 or asia-southeast1."
  }
}
