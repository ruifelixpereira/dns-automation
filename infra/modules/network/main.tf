locals {
  vnet_cidrs = {
    hub    = cidrsubnet(var.base_cidr, 2, 0)
    spoke1 = cidrsubnet(var.base_cidr, 2, 1)
    spoke2 = cidrsubnet(var.base_cidr, 2, 2)
  }
  resolver_subnets = {
    inbound  = cidrsubnet(local.vnet_cidrs.hub, 12, 0)
    outbound = cidrsubnet(local.vnet_cidrs.hub, 12, 1)
  }
  inbound_ip = cidrhost(local.resolver_subnets.inbound, 4)
}

resource "azurerm_virtual_network" "demo" {
  for_each = local.vnet_cidrs

  name                = "vnet-${var.name_prefix}-${each.key}"
  location            = var.location
  resource_group_name = var.network_resource_group_name
  address_space       = [each.value]
  dns_servers         = each.key == "hub" ? [] : [local.inbound_ip]
  tags                = var.tags
}

resource "azurerm_subnet" "private_endpoints" {
  for_each = local.vnet_cidrs

  name                              = "snet-private-endpoints"
  resource_group_name               = var.network_resource_group_name
  virtual_network_name              = azurerm_virtual_network.demo[each.key].name
  address_prefixes                  = [cidrsubnet(each.value, 8, 1)]
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${var.name_prefix}-private-endpoints"
  location            = var.location
  resource_group_name = var.network_resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowDemoHttps"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefixes    = values(local.vnet_cidrs)
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyOtherInbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  for_each = local.vnet_cidrs

  subnet_id                 = azurerm_subnet.private_endpoints[each.key].id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

resource "azurerm_subnet" "resolver" {
  #checkov:skip=CKV2_AZURE_31:Dedicated managed-resolver subnets contain no workload NICs; retain unobstructed DNS paths in this demo.
  for_each = local.resolver_subnets

  name                 = "snet-dns-${each.key}"
  resource_group_name  = var.network_resource_group_name
  virtual_network_name = azurerm_virtual_network.demo["hub"].name
  address_prefixes     = [each.value]

  delegation {
    name = "dns-resolver"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each = toset(["spoke1", "spoke2"])

  name                         = "peer-hub-${each.key}"
  resource_group_name          = var.network_resource_group_name
  virtual_network_name         = azurerm_virtual_network.demo["hub"].name
  remote_virtual_network_id    = azurerm_virtual_network.demo[each.key].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each = toset(["spoke1", "spoke2"])

  name                         = "peer-${each.key}-hub"
  resource_group_name          = var.network_resource_group_name
  virtual_network_name         = azurerm_virtual_network.demo[each.key].name
  remote_virtual_network_id    = azurerm_virtual_network.demo["hub"].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_private_dns_resolver" "hub" {
  name                = "dnspr-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resolver_resource_group_name
  virtual_network_id  = azurerm_virtual_network.demo["hub"].id
  tags                = var.tags
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "hub" {
  name                    = "inbound-${var.name_prefix}"
  location                = var.location
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  tags                    = var.tags

  ip_configurations {
    subnet_id                    = azurerm_subnet.resolver["inbound"].id
    private_ip_allocation_method = "Static"
    private_ip_address           = local.inbound_ip
  }
}

resource "azurerm_private_dns_resolver_outbound_endpoint" "hub" {
  name                    = "outbound-${var.name_prefix}"
  location                = var.location
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  subnet_id               = azurerm_subnet.resolver["outbound"].id
  tags                    = var.tags
}

resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "hub" {
  name                                       = "dnsfrs-${var.name_prefix}"
  location                                   = var.location
  resource_group_name                        = var.resolver_resource_group_name
  private_dns_resolver_outbound_endpoint_ids = [azurerm_private_dns_resolver_outbound_endpoint.hub.id]
  tags                                       = var.tags
}

resource "azurerm_private_dns_resolver_virtual_network_link" "hub" {
  name                      = "link-hub"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub.id
  virtual_network_id        = azurerm_virtual_network.demo["hub"].id
}

