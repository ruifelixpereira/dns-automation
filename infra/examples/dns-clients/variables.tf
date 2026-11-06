variable "ssh_public_key" {
  description = "Public SSH key required for Linux provisioning; no SSH access is opened. Never supply a private key."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "Supply an OpenSSH public key, not a private key or file path."
  }
}

variable "vm_size" {
  description = "Small Gen2/Trusted Launch-capable VM size available in your region and quota."
  type        = string
  default     = "Standard_B2ats_v2"
}
