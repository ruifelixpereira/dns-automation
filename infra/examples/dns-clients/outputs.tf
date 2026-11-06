output "clients" {
  description = "Private DNS test VMs, accessible administratively through Azure Run Command only."
  value = {
    for key, vm in azurerm_linux_virtual_machine.client : key => {
      id                  = vm.id
      name                = vm.name
      resource_group_name = vm.resource_group_name
    }
  }
}
