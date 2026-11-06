mock_provider "azurerm" {
  override_during = plan
}

override_data {
  target          = data.terraform_remote_state.foundation
  override_during = plan
  values = {
    outputs = {
      subscription_id = "11111111-1111-1111-1111-111111111111"
      location        = "westeurope"
      name_prefix     = "dnsdemo"
      resource_groups = { network = "rg-dnsdemo-network" }
      vnet_ids = {
        spoke1 = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/virtualNetworks/vnet-dnsdemo-spoke1"
        spoke2 = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/virtualNetworks/vnet-dnsdemo-spoke2"
      }
    }
  }
}

override_data {
  target          = data.azurerm_virtual_network.spoke["spoke1"]
  override_during = plan
  values          = { address_space = ["10.41.0.0/16"] }
}

override_data {
  target          = data.azurerm_virtual_network.spoke["spoke2"]
  override_during = plan
  values          = { address_space = ["10.42.0.0/16"] }
}

override_resource {
  target          = azurerm_nat_gateway.client["spoke1"]
  override_during = plan
  values          = { id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/natGateways/nat-dnsdemo-spoke1" }
}

override_resource {
  target          = azurerm_nat_gateway.client["spoke2"]
  override_during = plan
  values          = { id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dnsdemo-network/providers/Microsoft.Network/natGateways/nat-dnsdemo-spoke2" }
}

variables {
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA mock-only"
}

run "private_clients_and_explicit_egress" {
  command = plan

  assert {
    condition = (
      length(azurerm_linux_virtual_machine.client) == 2 &&
      alltrue([for nic in azurerm_network_interface.client : nic.ip_configuration[0].public_ip_address_id == null]) &&
      alltrue([for rule in azurerm_network_security_group.client.security_rule :
        rule.direction == "Inbound" && rule.access == "Deny" && rule.source_address_prefix == "*" && rule.destination_address_prefix == "*"
      ]) &&
      alltrue([for vm in azurerm_linux_virtual_machine.client :
        vm.disable_password_authentication && vm.secure_boot_enabled && vm.vtpm_enabled && vm.provision_vm_agent
      ])
    )
    error_message = "Both DNS clients must have private-only NICs, key-based provisioning, Trusted Launch and working VM agents."
  }

  assert {
    condition = (
      azurerm_subnet.client["spoke1"].address_prefixes == tolist(["10.41.2.0/24"]) &&
      azurerm_subnet.client["spoke2"].address_prefixes == tolist(["10.42.2.0/24"]) &&
      alltrue([for subnet in azurerm_subnet.client : !subnet.default_outbound_access_enabled]) &&
      length(azurerm_nat_gateway.client) == 2 &&
      length(azurerm_public_ip.nat) == 2 &&
      azurerm_subnet_nat_gateway_association.client["spoke1"].nat_gateway_id != azurerm_subnet_nat_gateway_association.client["spoke2"].nat_gateway_id
    )
    error_message = "Clients need dedicated subnets and separate per-VNet NAT gateways, not implicit/default outbound access."
  }
}

run "reject_private_key_material" {
  command = plan
  variables {
    ssh_public_key = "-----BEGIN OPENSSH PRIVATE KEY-----"
  }
  expect_failures = [var.ssh_public_key]
}
