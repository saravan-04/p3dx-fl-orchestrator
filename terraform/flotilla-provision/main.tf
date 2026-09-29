# Targets VMs that already exist (created separately via
# terraform/participant-vm's decentralized deploy.sh flow — this config
# does NOT create any VM). Provisions each one entirely via Azure's Custom
# Script Extension, which runs a script inside the VM through the Azure
# guest agent — no SSH connectivity from wherever `terraform apply` runs is
# needed at all, only Azure Resource Manager API access to the same
# subscription. See README.md for the full flow.

locals {
  orchestrator_vm_name  = "flo-user-${var.orchestrator_participant_name}"
  orchestrator_rg_name  = "rg-${local.orchestrator_vm_name}"
  orchestrator_nsg_name = "${local.orchestrator_vm_name}-nsg"

  # participant_name -> its VM name, for each data provider.
  data_provider_vm_names = {
    for name in var.data_provider_participant_names :
    name => "flo-data-provider-${name}"
  }

  generate_dataset_b64 = filebase64(var.generate_dataset_script_path)
}

data "azurerm_virtual_machine" "orchestrator" {
  name                = local.orchestrator_vm_name
  resource_group_name = local.orchestrator_rg_name
}

data "azurerm_virtual_machine" "data_provider" {
  for_each            = local.data_provider_vm_names
  name                = each.value
  resource_group_name = "rg-${each.value}"
}

# participant-vm's own NSG only opens 22/50051/50052-60 — add the REST API
# port as a standalone rule against that existing NSG (owned by
# participant-vm's own Terraform state) rather than managing the whole NSG
# resource here.
resource "azurerm_network_security_rule" "orchestrator_allow_rest" {
  name                        = "AllowFLRest"
  priority                    = 1004
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "12345"
  source_address_prefix       = var.allowed_fl_cidr
  destination_address_prefix  = "*"
  resource_group_name         = local.orchestrator_rg_name
  network_security_group_name = local.orchestrator_nsg_name
}

resource "azurerm_virtual_machine_extension" "provision_server" {
  name                       = "provision-flotilla-server"
  virtual_machine_id         = data.azurerm_virtual_machine.orchestrator.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    script = base64encode(templatefile("${path.module}/templates/provision-server.sh.tftpl", {
      flotilla_git_url     = var.flotilla_git_url
      flotilla_git_ref     = var.flotilla_git_ref
      generate_dataset_b64 = local.generate_dataset_b64
      discovery_type       = var.discovery_type
      image_tag            = var.image_tag
    }))
  })
}

resource "azurerm_virtual_machine_extension" "provision_client" {
  for_each = local.data_provider_vm_names

  name                       = "provision-flotilla-client"
  virtual_machine_id         = data.azurerm_virtual_machine.data_provider[each.key].id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    script = base64encode(templatefile("${path.module}/templates/provision-client.sh.tftpl", {
      flotilla_git_url      = var.flotilla_git_url
      flotilla_git_ref      = var.flotilla_git_ref
      generate_dataset_b64  = local.generate_dataset_b64
      discovery_type        = var.discovery_type
      image_tag             = var.image_tag
      participant_name      = each.key
      server_host           = data.azurerm_virtual_machine.orchestrator.public_ip_address
      client_advertise_host = data.azurerm_virtual_machine.data_provider[each.key].public_ip_address
    }))
  })
}

# Polls the orchestrator's REST API (locally, from whatever machine runs
# `terraform apply` — plain outbound HTTP, no SSH) until every client has
# actually registered, so start_session only fires once real connections
# exist.
resource "null_resource" "wait_for_clients" {
  depends_on = [
    azurerm_virtual_machine_extension.provision_server,
    azurerm_virtual_machine_extension.provision_client,
    azurerm_network_security_rule.orchestrator_allow_rest,
  ]

  triggers = {
    orchestrator_ip = data.azurerm_virtual_machine.orchestrator.public_ip_address
    client_names    = join(",", var.data_provider_participant_names)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = templatefile("${path.module}/templates/wait-for-clients.sh.tftpl", {
      server_ip        = data.azurerm_virtual_machine.orchestrator.public_ip_address
      rest_port        = 12345
      expected_clients = length(var.data_provider_participant_names)
      timeout_s        = var.wait_timeout_s
    })
  }
}

# Starts the FL session on the orchestrator VM itself (another Custom
# Script Extension — same no-SSH-needed mechanism), once wait_for_clients
# confirms every client is connected.
resource "azurerm_virtual_machine_extension" "start_session" {
  name                       = "start-flotilla-session"
  virtual_machine_id         = data.azurerm_virtual_machine.orchestrator.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    script = base64encode(templatefile("${path.module}/templates/start-session.sh.tftpl", {
      session_config_b64 = filebase64(var.session_config_path)
    }))
  })

  depends_on = [null_resource.wait_for_clients]
}
