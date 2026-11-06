output "private_dns_zone_ids" {
  description = "Expected service zone IDs; these zones are created by Policy."
  value       = local.zone_ids
}

output "assignment_id" {
  description = "Subscription initiative assignment ID."
  value       = azurerm_subscription_policy_assignment.dns.id
}

output "reference_ids" {
  description = "Policy reference IDs grouped by remediation stage."
  value = {
    zones  = ["create-zone-blob", "create-zone-vault"]
    links  = ["link-zone-hub"]
    groups = ["create-group-blob", "create-group-vault"]
    audits = ["audit-group-blob", "audit-group-vault"]
    deny   = ["deny-zone-location"]
  }
}
