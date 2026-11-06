resource "azurerm_user_assigned_identity" "policy" {
  name                = "id-${var.name_prefix}-dns-policy"
  location            = var.location
  resource_group_name = var.dns_resource_group_name
  tags                = var.tags
}

resource "azurerm_role_definition" "endpoint_remediation" {
  name        = "${var.name_prefix}-dns-endpoint-remediation"
  scope       = var.subscription_scope
  description = "Deploy DNS zone groups and join the demo hub VNet; no endpoint or VNet writes."

  permissions {
    actions = [
      "Microsoft.Network/privateEndpoints/read",
      "Microsoft.Network/privateEndpoints/privateDnsZoneGroups/read",
      "Microsoft.Network/privateEndpoints/privateDnsZoneGroups/write",
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/join/action",
      "Microsoft.Resources/deployments/*",
      "Microsoft.Resources/subscriptions/resourceGroups/read"
    ]
  }

  assignable_scopes = [var.network_resource_group_id]
}

resource "azurerm_role_assignment" "network" {
  scope              = var.network_resource_group_id
  role_definition_id = azurerm_role_definition.endpoint_remediation.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.policy.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "dns" {
  scope              = var.dns_resource_group_id
  role_definition_id = "${var.subscription_scope}${local.dns_role_id}"
  principal_id       = azurerm_user_assigned_identity.policy.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_policy_definition" "dns" {
  for_each = local.policies

  name         = "${var.name_prefix}-${each.key}"
  policy_type  = "Custom"
  mode         = "All"
  display_name = each.value.display_name
  description  = "Central DNS demo: ${each.value.display_name}. See the project README for ownership and remediation limits."
  metadata     = jsonencode({ category = "Network", version = "1.0.0" })
  parameters   = jsonencode(each.value.parameters)
  policy_rule  = jsonencode(each.value.rule)
}

resource "azurerm_policy_set_definition" "dns" {
  name         = "${var.name_prefix}-central-dns"
  policy_type  = "Custom"
  display_name = "Centralized private DNS demo (${var.name_prefix})"
  description  = "Four logical DNS requirements implemented by eight definitions; exact association auditing is non-destructive."
  metadata     = jsonencode({ category = "Network", version = "1.0.0" })
  parameters = jsonencode(merge(local.common_parameters, {
    denyEffect = {
      type          = "String"
      allowedValues = ["Deny", "Audit", "Disabled"]
      defaultValue  = "Audit"
    }
  }))

  dynamic "policy_definition_reference" {
    for_each = azurerm_policy_definition.dns
    content {
      policy_definition_id = policy_definition_reference.value.id
      reference_id         = policy_definition_reference.key
      parameter_values = jsonencode({
        for name in keys(local.policies[policy_definition_reference.key].parameters) :
        name => { value = "[parameters('${name}')]" }
      })
    }
  }
}

resource "azurerm_subscription_policy_assignment" "dns" {
  name                 = "${var.name_prefix}-central-dns"
  subscription_id      = var.subscription_scope
  policy_definition_id = azurerm_policy_set_definition.dns.id
  location             = var.location
  display_name         = "Centralized private DNS demo (${var.name_prefix})"
  enforce              = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.policy.id]
  }

  parameters = jsonencode({
    dnsResourceGroupName      = { value = var.dns_resource_group_name }
    endpointResourceGroupName = { value = var.network_resource_group_name }
    hubVnetId                 = { value = var.hub_vnet_id }
    denyEffect                = { value = var.enforce_zone_location ? "Deny" : "Audit" }
  })

  non_compliance_message {
    content = "Use the shared DNS resource group. Remediate zones, hub links, then missing endpoint zone groups; repair existing incorrect associations explicitly."
  }

  depends_on = [azurerm_role_assignment.network, azurerm_role_assignment.dns]
}
