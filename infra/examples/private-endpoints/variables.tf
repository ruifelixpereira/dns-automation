variable "foundation_state_path" {
  description = "Path to the foundation local state file; empty uses ../../terraform.tfstate relative to this module."
  type        = string
  default     = ""
}

variable "endpoints" {
  description = "Each entry creates a distinct service resource and endpoint; network is hub, spoke1 or spoke2."
  type = map(object({
    service = string
    network = string
  }))
  default = {
    blob-spoke1  = { service = "blob", network = "spoke1" }
    vault-spoke2 = { service = "vault", network = "spoke2" }
  }
  validation {
    condition = alltrue([
      for key, endpoint in var.endpoints :
      can(regex("^[a-z][a-z0-9-]{0,23}$", key)) &&
      contains(["blob", "vault"], endpoint.service) &&
      contains(["hub", "spoke1", "spoke2"], endpoint.network)
    ])
    error_message = "Endpoint keys must be 1-24 lowercase letters/digits/hyphens starting with a letter; choose blob/vault and hub/spoke1/spoke2."
  }
}
