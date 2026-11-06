output "endpoints" {
  description = "Endpoint IDs, expected private addresses, service FQDNs and expected shared-zone IDs."
  value = {
    for key, endpoint in var.endpoints : key => {
      id         = azurerm_private_endpoint.sample[key].id
      name       = azurerm_private_endpoint.sample[key].name
      network    = endpoint.network
      service    = endpoint.service
      private_ip = azurerm_private_endpoint.sample[key].private_service_connection[0].private_ip_address
      fqdn       = endpoint.service == "blob" ? "${azurerm_storage_account.sample[key].name}.blob.core.windows.net" : "${azurerm_key_vault.sample[key].name}.vault.azure.net"
      zone_id    = local.foundation.expected_private_dns_zone_ids[endpoint.service]
    }
  }
}
