locals {
  name_prefix = "flo-${var.role}-${var.participant_name}"

  tags = {
    project     = "p3dx-flo"
    role        = var.role
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

  # combine_fl's gRPC discovery: flo_server.py binds this on the user/
  # output-owner VM (server_config.yaml's grpc_discovery.port); data-provider
  # VMs' flo_client.py connects out to it (client_config.yaml's
  # grpc_discovery.host/port, wired by configure_broker below). Only matters
  # on the output-owner VM, but opening it unconditionally is simplest and
  # harmless — nothing listens on it on a data-provider VM.
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

  # combine_fl's client-side gRPC runtime server: flo_client.py itself binds
  # a server (client_config.yaml's grpc_runtime.sync_port, default 50054,
  # via a port_allocator that can step up a few ports if busy) that the
  # output-owner's flo_server.py connects back to for actual training
  # traffic. Only matters on data-provider VMs; harmless elsewhere.
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
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_public_ip" "this" {
  count               = var.enable_public_ip ? 1 : 0
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
    public_ip_address_id          = var.enable_public_ip ? azurerm_public_ip.this[0].id : null
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
# governance layer's vm-registry, so other participants/tooling can look up
# its IP later. See templates/configure-broker.sh.tftpl — this runs LOCALLY
# (not on the VM), since gov_layer is normally only reachable from the
# machine running terraform apply, not from the VM itself.
resource "null_resource" "configure_broker" {
  count = var.enable_public_ip ? 1 : 0

  triggers = {
    vm_id = azurerm_linux_virtual_machine.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = templatefile("${path.module}/templates/configure-broker.sh.tftpl", {
      self_ip          = azurerm_public_ip.this[0].ip_address
      role             = var.role
      participant_name = var.participant_name
      gov_layer_url    = var.gov_layer_url
      gov_layer_token  = var.gov_layer_token
    })
  }
}
