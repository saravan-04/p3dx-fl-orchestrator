output "orchestrator_public_ip" {
  value = data.azurerm_virtual_machine.orchestrator.public_ip_address
}

output "data_provider_public_ips" {
  value = { for k, vm in data.azurerm_virtual_machine.data_provider : k => vm.public_ip_address }
}

output "client_status_url" {
  description = "Check who's registered with the server."
  value       = "http://${data.azurerm_virtual_machine.orchestrator.public_ip_address}:12345/client_status"
}

output "session_status_hint" {
  description = "Once start_session has run, check progress via SSH to the orchestrator VM (if you have its key) or the Azure Portal's \"Run command\" on it: docker logs -f flotilla-server"
  value       = "docker logs -f flotilla-server"
}
