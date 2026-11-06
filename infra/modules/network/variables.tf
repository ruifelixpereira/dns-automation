terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

variable "name_prefix" {
  description = "Demo identifier used in resource names."
  type        = string
}

variable "location" {
  description = "Azure region for networking and resolver resources."
  type        = string
}

variable "network_resource_group_name" {
  description = "Resource group containing the VNets and subnets."
  type        = string
}

variable "resolver_resource_group_name" {
  description = "Resource group containing the resolver and ruleset."
  type        = string
}

variable "base_cidr" {
  description = "IPv4 /14 from which the three /16 networks are derived."
  type        = string
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
}
