output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.this.name
}

output "public_ip_address" {
  value = var.enable_public_ip ? azurerm_public_ip.this[0].ip_address : null
}

output "private_ip_address" {
  value = azurerm_network_interface.this.private_ip_address
}

output "ssh_command" {
  value = var.enable_public_ip ? "ssh ${var.admin_username}@${azurerm_public_ip.this[0].ip_address}" : "no public IP — reach ${azurerm_network_interface.this.private_ip_address} via VPN/Bastion/peering"
}
