terraform {
  required_version = ">= 1.12, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
  }
}

provider "azurerm" {
  subscription_id                 = data.terraform_remote_state.foundation.outputs.subscription_id
  resource_provider_registrations = "none"
  features {}
}
