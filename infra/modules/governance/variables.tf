terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

variable "name_prefix" {
  description = "Demo identifier used in governance resource names."
  type        = string
}

variable "location" {
  description = "Azure region for the assignment and managed identity."
  type        = string
}

variable "subscription_scope" {
  description = "Full subscription resource ID for definition and assignment scope."
  type        = string
}

variable "network_resource_group_id" {
  description = "Scope for endpoint remediation permissions."
  type        = string
}

variable "network_resource_group_name" {
  description = "Only endpoints in this resource group trigger service policies."
  type        = string
}

variable "dns_resource_group_id" {
  description = "Scope for shared DNS permissions and expected zone IDs."
  type        = string
}

variable "dns_resource_group_name" {
  description = "Shared resource group where private DNS zones are allowed."
  type        = string
}

variable "hub_vnet_id" {
  description = "VNet resource ID targeted by the zone-link policy."
  type        = string
}

variable "enforce_zone_location" {
  description = "True enables subscription-wide zone-location Deny; false audits."
  type        = bool
}

variable "tags" {
  description = "Tags for identity and policy-created DNS zones."
  type        = map(string)
}
