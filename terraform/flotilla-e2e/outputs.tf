output "orchestrator_public_ip" {
  value = module.orchestrator.public_ip_address
}

output "orchestrator_ssh_command" {
  value = module.orchestrator.ssh_command
}

output "data_provider_public_ips" {
  value = { for k, m in module.data_provider : k => m.public_ip_address }
}

output "data_provider_ssh_commands" {
  value = { for k, m in module.data_provider : k => m.ssh_command }
}

output "client_status_url" {
  description = "Check who's registered with the server."
  value       = "http://${module.orchestrator.public_ip_address}:12345/client_status"
}

output "session_status_hint" {
  description = "Once start_session has run, check progress on the orchestrator VM."
  value       = "ssh into the orchestrator (see orchestrator_ssh_command) and run: sudo docker logs -f flotilla-server"
}
