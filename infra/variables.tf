variable "subscription_id" {
  description = "Target subscription UUID. Use a dedicated demo subscription."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "location" {
  description = "Azure region supporting DNS Private Resolver."
  type        = string
  default     = "westeurope"
}

variable "name_prefix" {
  description = "Lowercase alphanumeric demo identifier, 3-16 characters."
  type        = string
  default     = "dnsdemo"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,15}$", var.name_prefix))
    error_message = "Use 3-16 lowercase letters/digits, starting with a letter."
  }
}

variable "base_cidr" {
  description = "An IPv4 /14 allocated to this demo. Three non-overlapping /16 VNets are derived from it."
  type        = string
  default     = "10.40.0.0/14"
  validation {
    condition     = can(cidrnetmask(var.base_cidr)) && can(regex("/14$", var.base_cidr))
    error_message = "base_cidr must be a valid IPv4 /14."
  }
}

variable "enforce_zone_location" {
  description = "Opt in to subscription-wide Deny outside the shared DNS resource group. False audits instead."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags; ownership and workload tags are set by the project."
  type        = map(string)
  default     = {}
}
