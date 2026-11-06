mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-dns/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-dnsdemo-dns-policy"
      principal_id = "22222222-2222-2222-2222-222222222222"
    }
  }

  mock_resource "azurerm_role_definition" {
    defaults = {
      role_definition_resource_id = "/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleDefinitions/33333333-3333-3333-3333-333333333333"
    }
  }
}

run "network_layout" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    name_prefix                  = "dnsdemo"
    location                     = "westeurope"
    network_resource_group_name  = "rg-dnsdemo-network"
    resolver_resource_group_name = "rg-dnsdemo-resolver"
    base_cidr                    = "10.40.0.0/14"
    tags                         = {}
  }

  assert {
    condition = (
      azurerm_virtual_network.demo["hub"].address_space == toset(["10.40.0.0/16"]) &&
      azurerm_virtual_network.demo["spoke1"].address_space == toset(["10.41.0.0/16"]) &&
      azurerm_virtual_network.demo["spoke2"].address_space == toset(["10.42.0.0/16"]) &&
      length(azurerm_subnet.private_endpoints) == 3 &&
      length(azurerm_virtual_network_peering.hub_to_spoke) == 2 &&
      length(azurerm_virtual_network_peering.spoke_to_hub) == 2
    )
    error_message = "The foundation must have three non-overlapping VNets, three PE subnets and bidirectional hub/spoke peerings."
  }

  assert {
    condition = (
      length(azurerm_virtual_network.demo["hub"].dns_servers) == 0 &&
      azurerm_virtual_network.demo["spoke1"].dns_servers == tolist([output.resolver_inbound_ip]) &&
      azurerm_virtual_network.demo["spoke2"].dns_servers == tolist([output.resolver_inbound_ip]) &&
      azurerm_private_dns_resolver_inbound_endpoint.hub.ip_configurations[0].private_ip_address == output.resolver_inbound_ip
    )
    error_message = "Both spokes must use the actual configured inbound IP while the hub remains on Azure-provided DNS."
  }

  assert {
    condition = (
      azurerm_subnet.resolver["inbound"].address_prefixes == tolist(["10.40.0.0/28"]) &&
      azurerm_subnet.resolver["outbound"].address_prefixes == tolist(["10.40.0.16/28"]) &&
      azurerm_subnet.private_endpoints["hub"].address_prefixes == tolist(["10.40.1.0/24"]) &&
      alltrue([for subnet in azurerm_subnet.resolver : subnet.delegation[0].service_delegation[0].name == "Microsoft.Network/dnsResolvers"])
    )
    error_message = "Resolver endpoints need distinct delegated /28 subnets, separate from the PE subnet."
  }
}

run "safe_governance" {
  command = plan

  module {
    source = "./modules/governance"
  }

  variables {
    name_prefix                 = "dnsdemo"
    location                    = "westeurope"
    subscription_scope          = "/subscriptions/11111111-1111-1111-1111-111111111111"
    network_resource_group_id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network"
    network_resource_group_name = "rg-dnsdemo-network"
    dns_resource_group_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-dns"
    dns_resource_group_name     = "rg-dnsdemo-dns"
    hub_vnet_id                 = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/virtualNetworks/vnet-dnsdemo-hub"
    enforce_zone_location       = false
    tags                        = {}
  }

  assert {
    condition = (
      jsondecode(azurerm_subscription_policy_assignment.dns.parameters).denyEffect.value == "Audit" &&
      azurerm_role_assignment.network.scope == var.network_resource_group_id &&
      azurerm_role_assignment.dns.scope == var.dns_resource_group_id &&
      !contains(azurerm_role_definition.endpoint_remediation.permissions[0].actions, "Microsoft.Network/*")
    )
    error_message = "Deny must be opt-in and remediation rights must not be subscription-wide Network Contributor."
  }

  assert {
    condition = alltrue([
      for policy in azurerm_policy_definition.dns : alltrue([
        for name in keys(jsondecode(policy.parameters)) : strcontains(policy.policy_rule, "parameters('${name}')")
      ])
    ])
    error_message = "Azure rejects policy definitions with unused parameters."
  }

  assert {
    condition = alltrue([
      for reference in azurerm_policy_set_definition.dns.policy_definition_reference :
      alltrue([
        for name in keys(jsondecode(azurerm_policy_definition.dns[reference.reference_id].parameters)) :
        jsondecode(reference.parameter_values)[name].value == "[parameters('${name}')]"
      ])
    ])
    error_message = "Initiative references must supply exactly the parameters expected by each definition."
  }

  assert {
    condition = alltrue([
      for service in ["blob", "vault"] :
      !can(jsondecode(azurerm_policy_definition.dns["create-group-${service}"].policy_rule).then.details.existenceCondition) &&
      jsondecode(azurerm_policy_definition.dns["audit-group-${service}"].policy_rule).then.details.existenceCondition.count.where.equals == output.private_dns_zone_ids[service] &&
      jsondecode(azurerm_policy_definition.dns["create-zone-${service}"].policy_rule).then.details.existenceCondition.equals == output.private_dns_zone_ids[service]
    ])
    error_message = "Any existing group must block destructive replacement, but audit and zone checks must use the exact shared-zone ID."
  }

  assert {
    condition = (
      jsondecode(azurerm_policy_definition.dns["link-zone-hub"].policy_rule).then.details.existenceCondition.allOf[0].equals == "[parameters('hubVnetId')]" &&
      jsondecode(azurerm_policy_definition.dns["link-zone-hub"].policy_rule).then.details.existenceCondition.allOf[1].equals == false &&
      jsondecode(azurerm_policy_definition.dns["link-zone-hub"].policy_rule).then.details.deployment.properties.template.resources[0].properties.registrationEnabled == false
    )
    error_message = "Hub-link compliance and deployment must both disable auto-registration and target the hub."
  }
}

run "deny_opt_in" {
  command = plan

  module {
    source = "./modules/governance"
  }

  variables {
    name_prefix                 = "dnsdemo"
    location                    = "westeurope"
    subscription_scope          = "/subscriptions/11111111-1111-1111-1111-111111111111"
    network_resource_group_id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network"
    network_resource_group_name = "rg-dnsdemo-network"
    dns_resource_group_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-dns"
    dns_resource_group_name     = "rg-dnsdemo-dns"
    hub_vnet_id                 = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/virtualNetworks/vnet-dnsdemo-hub"
    enforce_zone_location       = true
    tags                        = {}
  }

  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.dns.parameters).denyEffect.value == "Deny"
    error_message = "Explicitly opting in must activate the location Deny policy."
  }
}

run "invalid_address_space" {
  command = plan

  variables {
    subscription_id = "11111111-1111-1111-1111-111111111111"
    base_cidr       = "10.40.0.0/24"
  }

  expect_failures = [var.base_cidr]
}
