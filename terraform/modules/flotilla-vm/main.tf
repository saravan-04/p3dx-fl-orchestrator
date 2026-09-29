locals {
  name_prefix  = "flo-${var.role}-${var.participant_name}"
  remote_home  = "/home/${var.admin_username}"
  flotilla_dir = "${local.remote_home}/flotilla"

  tags = {
    project     = "p3dx-flo"
    role        = var.role
    workload    = var.flotilla_workload
    participant = var.participant_name
    created_by  = coalesce(var.created_by, "unknown")
    managed_by  = "terraform"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${local.name_prefix}-vnet"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_prefix]
}

resource "azurerm_network_security_group" "this" {
  name                = "${local.name_prefix}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  # combine_fl's gRPC discovery: flo_server.py binds this on the server VM;
  # a data-provider VM's flo_client.py connects out to it (SERVER_GRPC_HOST).
  security_rule {
    name                       = "AllowFLDiscovery"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "50051"
    source_address_prefix      = var.allowed_fl_cidr
    destination_address_prefix = "*"
  }

  # combine_fl's client-side gRPC runtime server: flo_client.py binds this
  # (client_config.yaml's grpc_runtime ports, stepped up a few if busy) so
  # the server can dial back into the client for actual training traffic.
  # Only matters on a client VM; harmless elsewhere.
  security_rule {
    name                       = "AllowFLClientRuntime"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "50052-50060"
    source_address_prefix      = var.allowed_fl_cidr
    destination_address_prefix = "*"
  }

  # flo_server.py's REST API (session start/status, client_status). Only
  # matters on the server VM — needed both by the flotilla-session
  # container and by the wait-for-clients poll in terraform/flotilla-e2e.
  security_rule {
    name                       = "AllowFLRest"
    priority                   = 1004
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "12345"
    source_address_prefix      = var.allowed_fl_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_public_ip" "this" {
  name                = "${local.name_prefix}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "this" {
  name                = "${local.name_prefix}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = local.name_prefix
  computer_name                   = substr(local.name_prefix, 0, 63)
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  network_interface_ids           = [azurerm_network_interface.this.id]
  disable_password_authentication = true
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "${local.name_prefix}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# Registers this VM's {role, participant_name, ip_address} with the
# governance layer's vm-registry, for visibility/consistency with
# terraform/participant-vm's decentralized flow. Runs LOCALLY (not on the
# VM) — see that module's README for why. Best-effort: failure warns but
# doesn't fail terraform apply.
resource "null_resource" "configure_broker" {
  triggers = {
    vm_id = azurerm_linux_virtual_machine.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = templatefile("${path.module}/templates/configure-broker.sh.tftpl", {
      self_ip          = azurerm_public_ip.this.ip_address
      role             = var.role
      participant_name = var.participant_name
      gov_layer_url    = var.gov_layer_url
      gov_layer_token  = var.gov_layer_token
    })
  }
}

# Copies the Flotilla_Deployment source to the VM and builds/starts the
# right container for flotilla_workload. Runs over SSH from whatever
# machine executes `terraform apply` (same posture as configure_broker).
resource "null_resource" "provision_flotilla" {
  depends_on = [azurerm_linux_virtual_machine.this]

  triggers = {
    vm_id = azurerm_linux_virtual_machine.this.id
  }

  connection {
    type        = "ssh"
    host        = azurerm_public_ip.this.ip_address
    user        = var.admin_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ${local.flotilla_dir}/deployment ${local.flotilla_dir}/src ${local.flotilla_dir}/config ${local.flotilla_dir}/models",
    ]
  }

  provisioner "file" {
    source      = "${var.flotilla_source_path}/deployment/"
    destination = "${local.flotilla_dir}/deployment"
  }

  provisioner "file" {
    source      = "${var.flotilla_source_path}/src/"
    destination = "${local.flotilla_dir}/src"
  }

  provisioner "file" {
    source      = "${var.flotilla_source_path}/config/"
    destination = "${local.flotilla_dir}/config"
  }

  provisioner "file" {
    source      = "${var.flotilla_source_path}/models/"
    destination = "${local.flotilla_dir}/models"
  }

  provisioner "file" {
    source      = "${var.flotilla_source_path}/generate_dataset.py"
    destination = "${local.flotilla_dir}/generate_dataset.py"
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/provision.sh.tftpl", {
      role                   = var.flotilla_workload
      participant_name       = var.participant_name
      server_host             = coalesce(var.server_host, "")
      client_advertise_host  = azurerm_public_ip.this.ip_address
      discovery_type         = var.discovery_type
      monitor                = var.monitor
      image_tag              = var.image_tag
      flotilla_dir           = local.flotilla_dir
    })
    destination = "/tmp/provision.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision.sh",
      "/tmp/provision.sh",
    ]
  }
}
