output "vnet_ids" {
  description = "VNet resource IDs keyed by hub/spoke name."
  value       = { for key, vnet in azurerm_virtual_network.demo : key => vnet.id }
}

output "private_endpoint_subnet_ids" {
  description = "Dedicated private endpoint subnets keyed by VNet name."
  value       = { for key, subnet in azurerm_subnet.private_endpoints : key => subnet.id }
}

output "resolver_inbound_ip" {
  description = "Static inbound DNS address used by both spokes."
  value       = local.inbound_ip
}
