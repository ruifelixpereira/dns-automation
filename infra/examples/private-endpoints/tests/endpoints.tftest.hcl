mock_provider "azurerm" {
  override_during = plan

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "22222222-2222-2222-2222-222222222222"
    }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      subscription_id = "11111111-1111-1111-1111-111111111111"
      location        = "westeurope"
      name_prefix     = "dnsdemo"
      resource_groups = { network = "rg-dnsdemo-network" }
      private_endpoint_subnet_ids = {
        hub    = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/virtualNetworks/vnet-dnsdemo-hub/subnets/snet-private-endpoints"
        spoke1 = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/virtualNetworks/vnet-dnsdemo-spoke1/subnets/snet-private-endpoints"
        spoke2 = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/virtualNetworks/vnet-dnsdemo-spoke2/subnets/snet-private-endpoints"
      }
      expected_private_dns_zone_ids = {
        blob  = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
        vault = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
      }
    }
  }
}

run "isolated_private_samples" {
  command = plan

  assert {
    condition = (
      length(azurerm_private_endpoint.sample["blob-spoke1"].private_dns_zone_group) == 0 &&
      length(azurerm_private_endpoint.sample["vault-spoke2"].private_dns_zone_group) == 0 &&
      azurerm_private_endpoint.sample["blob-spoke1"].subnet_id == local.foundation.private_endpoint_subnet_ids.spoke1 &&
      azurerm_private_endpoint.sample["vault-spoke2"].subnet_id == local.foundation.private_endpoint_subnet_ids.spoke2 &&
      azurerm_private_endpoint.sample["blob-spoke1"].private_service_connection[0].subresource_names == tolist(["blob"]) &&
      azurerm_private_endpoint.sample["vault-spoke2"].private_service_connection[0].subresource_names == tolist(["vault"])
    )
    error_message = "Samples must exercise Policy by omitting zone groups and using the appropriate service IDs in different spokes."
  }

  assert {
    condition = (
      azurerm_storage_account.sample["blob-spoke1"].public_network_access == "Disabled" &&
      !azurerm_storage_account.sample["blob-spoke1"].shared_access_key_enabled &&
      azurerm_storage_account.sample["blob-spoke1"].min_tls_version == "TLS1_2" &&
      !azurerm_key_vault.sample["vault-spoke2"].public_network_access_enabled &&
      azurerm_key_vault.sample["vault-spoke2"].rbac_authorization_enabled &&
      azurerm_key_vault.sample["vault-spoke2"].purge_protection_enabled
    )
    error_message = "Sample services must remain private, use Entra authorization and protect Key Vault deletion."
  }
}

run "hub_and_concurrent_resources" {
  command = plan

  variables {
    endpoints = {
      blob-hub    = { service = "blob", network = "hub" }
      blob-spoke1 = { service = "blob", network = "spoke1" }
      blob-spoke2 = { service = "blob", network = "spoke2" }
    }
  }

  assert {
    condition = (
      length(azurerm_storage_account.sample) == 3 &&
      length(toset([for account in azurerm_storage_account.sample : account.name])) == 3 &&
      azurerm_private_endpoint.sample["blob-hub"].subnet_id == local.foundation.private_endpoint_subnet_ids.hub
    )
    error_message = "Hub and concurrency tests must create distinct service resources rather than competing for one DNS record name."
  }
}

run "unsupported_service" {
  command = plan

  variables {
    endpoints = {
      sql-spoke1 = { service = "sqlServer", network = "spoke1" }
    }
  }

  expect_failures = [var.endpoints]
}
