# One coordinated apply: provisions the orchestrator (flotilla-server) VM
# and every data-provider (flotilla-client) VM, waits for all clients to
# register with the server, then triggers the FL session on the
# orchestrator. See README.md for the full flow and prerequisites.

module "orchestrator" {
  source = "../modules/flotilla-vm"

  subscription_id  = var.subscription_id
  role             = "user"
  flotilla_workload = "server"
  participant_name = "${var.participant_name_prefix}-orchestrator"
  created_by       = var.created_by

  location              = var.location
  vm_size               = var.vm_size
  admin_username        = var.admin_username
  ssh_public_key_path   = var.ssh_public_key_path
  ssh_private_key_path  = var.ssh_private_key_path
  flotilla_source_path  = var.flotilla_source_path

  discovery_type = var.discovery_type
  image_tag      = var.image_tag

  gov_layer_url    = var.gov_layer_url
  gov_layer_token  = var.gov_layer_token
  allowed_ssh_cidr = var.allowed_ssh_cidr
  allowed_fl_cidr  = var.allowed_fl_cidr
}

module "data_provider" {
  source   = "../modules/flotilla-vm"
  for_each = toset(var.data_provider_names)

  subscription_id  = var.subscription_id
  role             = "data-provider"
  flotilla_workload = "client"
  participant_name = "${var.participant_name_prefix}-${each.key}"
  created_by       = var.created_by

  # Wired directly from the orchestrator module's output — this is a single
  # coordinated apply, so there's no need to round-trip through gov_layer's
  # vm-registry lookup (that's what terraform/participant-vm's decentralized
  # flow does, where the two sides aren't provisioned together).
  server_host = module.orchestrator.public_ip_address

  location              = var.location
  vm_size               = var.vm_size
  admin_username        = var.admin_username
  ssh_public_key_path   = var.ssh_public_key_path
  ssh_private_key_path  = var.ssh_private_key_path
  flotilla_source_path  = var.flotilla_source_path

  discovery_type = var.discovery_type
  image_tag      = var.image_tag

  gov_layer_url    = var.gov_layer_url
  gov_layer_token  = var.gov_layer_token
  allowed_ssh_cidr = var.allowed_ssh_cidr
  allowed_fl_cidr  = var.allowed_fl_cidr
}

# Polls the orchestrator's REST API (locally, not on any VM) until every
# data-provider client has registered, so start_session only fires once
# real client<->server connections exist.
resource "null_resource" "wait_for_clients" {
  depends_on = [module.orchestrator, module.data_provider]

  triggers = {
    orchestrator_ip = module.orchestrator.public_ip_address
    client_vm_ids   = join(",", [for k, m in module.data_provider : m.vm_name])
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = templatefile("${path.module}/templates/wait-for-clients.sh.tftpl", {
      server_ip        = module.orchestrator.public_ip_address
      rest_port        = 12345
      expected_clients = length(var.data_provider_names)
      timeout_s        = var.wait_timeout_s
    })
  }
}

# Starts the FL session on the orchestrator VM itself, once wait_for_clients
# confirms every client is connected.
resource "null_resource" "start_session" {
  depends_on = [null_resource.wait_for_clients]

  triggers = {
    orchestrator_ip = module.orchestrator.public_ip_address
    session_config  = filemd5(var.session_config_path)
  }

  connection {
    type        = "ssh"
    host        = module.orchestrator.public_ip_address
    user        = var.admin_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "2m"
  }

  provisioner "file" {
    source      = var.session_config_path
    destination = "/home/${var.admin_username}/flotilla/config/session_config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'STAGE: Starting FL session on orchestrator'",
      "sudo docker run --rm --network host -e SERVER_ENDPOINT=localhost:12345 -e SESSION_TASK=start_session -e SESSION_CONFIG_PATH=/session/session_config.yaml -v /home/${var.admin_username}/flotilla/config/session_config.yaml:/session/session_config.yaml:ro flotilla-session:latest",
      "echo 'STAGE: session request sent'",
    ]
  }
}
