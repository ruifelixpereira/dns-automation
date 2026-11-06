output "subscription_id" {
  description = "Subscription used by this foundation."
  value       = var.subscription_id
}

output "location" {
  description = "Deployment region."
  value       = var.location
}

output "name_prefix" {
  description = "Demo naming prefix."
  value       = var.name_prefix
}

output "resource_groups" {
  description = "Resource group names by purpose."
  value       = { for key, group in azurerm_resource_group.demo : key => group.name }
}

output "vnet_ids" {
  description = "Hub and spoke VNet resource IDs."
  value       = module.network.vnet_ids
}

output "private_endpoint_subnet_ids" {
  description = "Private endpoint subnet IDs by VNet."
  value       = module.network.private_endpoint_subnet_ids
}

output "resolver_inbound_ip" {
  description = "Custom DNS server configured on both spokes."
  value       = module.network.resolver_inbound_ip
}

output "expected_private_dns_zone_ids" {
  description = "Expected IDs, not evidence of zone existence. Policy creates zones on demand."
  value       = module.governance.private_dns_zone_ids
}

output "policy_assignment_id" {
  description = "Initiative assignment ID for compliance and remediation."
  value       = module.governance.assignment_id
}

output "policy_reference_ids" {
  description = "Reference IDs used for staged remediation."
  value       = module.governance.reference_ids
}
