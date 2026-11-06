data "terraform_remote_state" "foundation" {
  backend = "local"
  config  = { path = "${path.module}/../../terraform.tfstate" }
}

locals {
  foundation = data.terraform_remote_state.foundation.outputs
  spokes     = toset(["spoke1", "spoke2"])
  tags = {
    environment = "demo"
    workload    = "central-private-dns-clients"
    managed-by  = "terraform"
  }
}

data "azurerm_virtual_network" "spoke" {
  for_each = local.spokes

  name                = reverse(split("/", local.foundation.vnet_ids[each.key]))[0]
  resource_group_name = local.foundation.resource_groups.network
}

resource "azurerm_subnet" "client" {
  for_each = local.spokes

  name                            = "snet-dns-demo-clients"
  resource_group_name             = local.foundation.resource_groups.network
  virtual_network_name            = data.azurerm_virtual_network.spoke[each.key].name
  address_prefixes                = [cidrsubnet(tolist(data.azurerm_virtual_network.spoke[each.key].address_space)[0], 8, 2)]
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "client" {
  name                = "nsg-${local.foundation.name_prefix}-dns-clients"
  location            = local.foundation.location
  resource_group_name = local.foundation.resource_groups.network
  tags                = local.tags

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "client" {
  for_each = local.spokes

  subnet_id                 = azurerm_subnet.client[each.key].id
  network_security_group_id = azurerm_network_security_group.client.id
}

resource "azurerm_public_ip" "nat" {
  for_each = local.spokes

  name                = "pip-${local.foundation.name_prefix}-${each.key}-egress"
  location            = local.foundation.location
  resource_group_name = local.foundation.resource_groups.network
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "client" {
  for_each = local.spokes

  name                = "nat-${local.foundation.name_prefix}-${each.key}"
  location            = local.foundation.location
  resource_group_name = local.foundation.resource_groups.network
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "client" {
  for_each = local.spokes

  nat_gateway_id       = azurerm_nat_gateway.client[each.key].id
  public_ip_address_id = azurerm_public_ip.nat[each.key].id
}

resource "azurerm_subnet_nat_gateway_association" "client" {
  for_each = local.spokes

  subnet_id      = azurerm_subnet.client[each.key].id
  nat_gateway_id = azurerm_nat_gateway.client[each.key].id
}

resource "azurerm_network_interface" "client" {
  for_each = local.spokes

  name                = "nic-${local.foundation.name_prefix}-${each.key}-client"
  location            = local.foundation.location
  resource_group_name = local.foundation.resource_groups.network
  tags                = local.tags

  ip_configuration {
    name                          = "private"
    subnet_id                     = azurerm_subnet.client[each.key].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "client" {
  for_each = local.spokes

  name                            = "vm-${local.foundation.name_prefix}-${each.key}-dns"
  location                        = local.foundation.location
  resource_group_name             = local.foundation.resource_groups.network
  size                            = var.vm_size
  admin_username                  = "demoadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.client[each.key].id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  provision_vm_agent              = true
  allow_extension_operations      = true
  tags                            = local.tags

  admin_ssh_key {
    username   = "demoadmin"
    public_key = trimspace(var.ssh_public_key)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {}

  depends_on = [
    azurerm_subnet_network_security_group_association.client,
    azurerm_nat_gateway_public_ip_association.client,
    azurerm_subnet_nat_gateway_association.client
  ]
}
