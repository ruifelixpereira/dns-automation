locals {
  services = {
    blob = {
      resource_type = "Microsoft.Storage/storageAccounts"
      group_id      = "blob"
      zone_name     = "privatelink.blob.core.windows.net"
    }
    vault = {
      resource_type = "Microsoft.KeyVault/vaults"
      group_id      = "vault"
      zone_name     = "privatelink.vaultcore.azure.net"
    }
  }
  zone_ids = {
    for key, service in local.services :
    key => "${var.dns_resource_group_id}/providers/Microsoft.Network/privateDnsZones/${service.zone_name}"
  }
  dns_role_id = "/providers/Microsoft.Authorization/roleDefinitions/b12aa53e-6015-4669-85d0-8515ebb3ae7f"
  common_parameters = {
    dnsResourceGroupName      = { type = "String" }
    endpointResourceGroupName = { type = "String" }
    hubVnetId                 = { type = "String" }
  }
  endpoint_parameters = {
    endpointResourceGroupName = local.common_parameters.endpointResourceGroupName
  }
  template_schema = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"

  endpoint_conditions = {
    for key, service in local.services : key => {
      allOf = [
        { field = "type", equals = "Microsoft.Network/privateEndpoints" },
        { value = "[resourceGroup().name]", equals = "[parameters('endpointResourceGroupName')]" },
        {
          anyOf = [
            for connection in ["privateLinkServiceConnections", "manualPrivateLinkServiceConnections"] : {
              count = {
                field = "Microsoft.Network/privateEndpoints/${connection}[*]"
                where = {
                  allOf = [
                    {
                      field    = "Microsoft.Network/privateEndpoints/${connection}[*].privateLinkServiceId"
                      contains = "/providers/${service.resource_type}/"
                    },
                    {
                      count = {
                        field = "Microsoft.Network/privateEndpoints/${connection}[*].groupIds[*]"
                        where = {
                          field  = "Microsoft.Network/privateEndpoints/${connection}[*].groupIds[*]"
                          equals = service.group_id
                        }
                      }
                      greaterOrEquals = 1
                    }
                  ]
                }
              }
              greaterOrEquals = 1
            }
          ]
        }
      ]
    }
  }

  create_group_policies = {
    for key, service in local.services : "create-group-${key}" => {
      display_name = "Create missing shared DNS zone group (${key})"
      parameters   = local.endpoint_parameters
      rule = {
        "if" = local.endpoint_conditions[key]
        then = {
          effect = "DeployIfNotExists"
          details = {
            type              = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups"
            evaluationDelay   = "AfterProvisioningSuccess"
            roleDefinitionIds = [azurerm_role_definition.endpoint_remediation.role_definition_resource_id, local.dns_role_id]
            # Any existing group prevents replacement; the audit below checks its exact association.
            deployment = {
              properties = {
                mode = "Incremental"
                template = {
                  "$schema"      = local.template_schema
                  contentVersion = "1.0.0.0"
                  parameters = {
                    endpointName = { type = "string" }
                    location     = { type = "string" }
                  }
                  resources = [{
                    type       = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups"
                    apiVersion = "2024-07-01"
                    name       = "[concat(parameters('endpointName'), '/deployedByPolicy')]"
                    location   = "[parameters('location')]"
                    properties = {
                      privateDnsZoneConfigs = [{
                        name       = key
                        properties = { privateDnsZoneId = local.zone_ids[key] }
                      }]
                    }
                  }]
                }
                parameters = {
                  endpointName = { value = "[field('name')]" }
                  location     = { value = "[field('location')]" }
                }
              }
            }
          }
        }
      }
    }
  }

  audit_group_policies = {
    for key, service in local.services : "audit-group-${key}" => {
      display_name = "Audit exact shared DNS zone association (${key})"
      parameters   = local.endpoint_parameters
      rule = {
        "if" = local.endpoint_conditions[key]
        then = {
          effect = "AuditIfNotExists"
          details = {
            type            = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups"
            evaluationDelay = "AfterProvisioningSuccess"
            existenceCondition = {
              count = {
                field = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups/privateDnsZoneConfigs[*]"
                where = {
                  field  = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups/privateDnsZoneConfigs[*].privateDnsZoneId"
                  equals = local.zone_ids[key]
                }
              }
              greaterOrEquals = 1
            }
          }
        }
      }
    }
  }

  create_zone_policies = {
    for key, service in local.services : "create-zone-${key}" => {
      display_name = "Create missing centralized private DNS zone (${key})"
      parameters = merge(local.endpoint_parameters, {
        dnsResourceGroupName = local.common_parameters.dnsResourceGroupName
      })
      rule = {
        "if" = local.endpoint_conditions[key]
        then = {
          effect = "DeployIfNotExists"
          details = {
            type              = "Microsoft.Network/privateDnsZones"
            name              = service.zone_name
            resourceGroupName = "[parameters('dnsResourceGroupName')]"
            existenceScope    = "ResourceGroup"
            deploymentScope   = "ResourceGroup"
            evaluationDelay   = "AfterProvisioningSuccess"
            roleDefinitionIds = [local.dns_role_id]
            existenceCondition = {
              field  = "id"
              equals = local.zone_ids[key]
            }
            deployment = {
              properties = {
                mode = "Incremental"
                template = {
                  "$schema"      = local.template_schema
                  contentVersion = "1.0.0.0"
                  resources = [{
                    type       = "Microsoft.Network/privateDnsZones"
                    apiVersion = "2024-06-01"
                    name       = service.zone_name
                    location   = "global"
                    tags       = merge(var.tags, { managed-by = "azure-policy" })
                    properties = {}
                  }]
                }
              }
            }
          }
        }
      }
    }
  }

  policies = merge(local.create_group_policies, local.audit_group_policies, local.create_zone_policies, {
    deny-zone-location = {
      display_name = "Restrict all private DNS zones to the shared resource group"
      parameters = {
        dnsResourceGroupName = local.common_parameters.dnsResourceGroupName
        denyEffect = {
          type          = "String"
          allowedValues = ["Deny", "Audit", "Disabled"]
          defaultValue  = "Audit"
        }
      }
      rule = {
        "if" = {
          allOf = [
            { field = "type", equals = "Microsoft.Network/privateDnsZones" },
            { value = "[resourceGroup().name]", notEquals = "[parameters('dnsResourceGroupName')]" }
          ]
        }
        then = { effect = "[parameters('denyEffect')]" }
      }
    }
    link-zone-hub = {
      display_name = "Link shared private DNS zones to the hub without auto-registration"
      parameters = {
        dnsResourceGroupName = local.common_parameters.dnsResourceGroupName
        hubVnetId            = local.common_parameters.hubVnetId
      }
      rule = {
        "if" = {
          allOf = [
            { field = "type", equals = "Microsoft.Network/privateDnsZones" },
            { value = "[resourceGroup().name]", equals = "[parameters('dnsResourceGroupName')]" }
          ]
        }
        then = {
          effect = "DeployIfNotExists"
          details = {
            type              = "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
            evaluationDelay   = "AfterProvisioningSuccess"
            roleDefinitionIds = [local.dns_role_id, azurerm_role_definition.endpoint_remediation.role_definition_resource_id]
            existenceCondition = {
              allOf = [
                {
                  field  = "Microsoft.Network/privateDnsZones/virtualNetworkLinks/virtualNetwork.id"
                  equals = "[parameters('hubVnetId')]"
                },
                {
                  field  = "Microsoft.Network/privateDnsZones/virtualNetworkLinks/registrationEnabled"
                  equals = false
                }
              ]
            }
            deployment = {
              properties = {
                mode = "Incremental"
                template = {
                  "$schema"      = local.template_schema
                  contentVersion = "1.0.0.0"
                  parameters = {
                    zoneName  = { type = "string" }
                    hubVnetId = { type = "string" }
                  }
                  resources = [{
                    type       = "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
                    apiVersion = "2024-06-01"
                    name       = "[concat(parameters('zoneName'), '/hub-${var.name_prefix}')]"
                    location   = "global"
                    properties = {
                      virtualNetwork      = { id = "[parameters('hubVnetId')]" }
                      registrationEnabled = false
                    }
                  }]
                }
                parameters = {
                  zoneName  = { value = "[field('name')]" }
                  hubVnetId = { value = "[parameters('hubVnetId')]" }
                }
              }
            }
          }
        }
      }
    }
  })
}
