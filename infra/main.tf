locals {
  subscription_scope = "/subscriptions/${var.subscription_id}"
  tags = merge(var.tags, {
    environment = "demo"
    workload    = "central-private-dns"
    managed-by  = "terraform"
  })
}

resource "azurerm_resource_group" "demo" {
  for_each = toset(["network", "dns", "resolver"])

  name     = "rg-${var.name_prefix}-${each.key}"
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "./modules/network"

  name_prefix                  = var.name_prefix
  location                     = var.location
  network_resource_group_name  = azurerm_resource_group.demo["network"].name
  resolver_resource_group_name = azurerm_resource_group.demo["resolver"].name
  base_cidr                    = var.base_cidr
  tags                         = local.tags
}

module "governance" {
  source = "./modules/governance"

  name_prefix                 = var.name_prefix
  location                    = var.location
  subscription_scope          = local.subscription_scope
  network_resource_group_id   = azurerm_resource_group.demo["network"].id
  network_resource_group_name = azurerm_resource_group.demo["network"].name
  dns_resource_group_id       = azurerm_resource_group.demo["dns"].id
  dns_resource_group_name     = azurerm_resource_group.demo["dns"].name
  hub_vnet_id                 = module.network.vnet_ids["hub"]
  enforce_zone_location       = var.enforce_zone_location
  tags                        = local.tags
}
