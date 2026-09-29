variable "subscription_id" {
  description = "Azure subscription ID to deploy into (the participant's own subscription). Leave null to use the subscription already selected via `az account set`."
  type        = string
  default     = null
}

variable "role" {
  description = "Who this VM belongs to: \"data-provider\" or \"user\". Used only for naming/tags."
  type        = string

  validation {
    condition     = contains(["data-provider", "user"], var.role)
    error_message = "role must be \"data-provider\" or \"user\"."
  }
}

variable "participant_name" {
  description = "Short, unique, lowercase-with-dashes identifier for this participant, used in the VM name/tags. When run via deploy.sh this is auto-derived from the signed-in Azure identity (az account show); set it explicitly here to override, or if you're calling terraform directly."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,20}[a-z0-9])?$", var.participant_name))
    error_message = "participant_name must be 1-22 lowercase alphanumeric characters/dashes, and not start or end with a dash."
  }
}

variable "created_by" {
  description = "The signed-in Azure identity (UPN/appId) that created this VM. Auto-filled by deploy.sh from `az account show`; stored as a tag for traceability. Optional."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "centralindia"
}

variable "vm_size" {
  description = "VM size. Standard_B2s_v2 (2 vCPU / 4 GiB, burstable) is cheap and, per `az vm list-skus`, has no capacity restrictions in CentralIndia — unlike Standard_B1s and Standard_B2s (both v1), which frequently hit SkuNotAvailable there."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "admin_username" {
  description = "Linux admin username created on the VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install for admin_username. SSH key auth only — no passwords."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "gov_layer_url" {
  description = "Base URL (including /api/v1) of the p3dx governance layer's REST API, reachable from wherever you run terraform apply — NOT from the VM itself (see README's \"broker_host wiring\" section). Used to register this VM's IP and, for a data-provider VM, to look up the output-owner's IP."
  type        = string
  default     = "http://localhost:8083/api/v1"
}

variable "gov_layer_token" {
  description = "Shared secret sent as X-VM-Registry-Token to gov_layer's vm-registry endpoints, matching its VM_REGISTRY_TOKEN env var. Leave blank if gov_layer doesn't have VM_REGISTRY_TOKEN set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22 (e.g. \"203.0.113.10/32\" for just your IP). Defaults to open, which is fine for a quick throwaway VM but should be tightened for anything longer-lived."
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_fl_cidr" {
  description = "CIDR allowed to reach combine_fl's gRPC ports (50051 discovery, 50052-50060 client runtime) — see the two AllowFL* security rules. Defaults to open like allowed_ssh_cidr; tighten to the other participants' IPs once known."
  type        = string
  default     = "0.0.0.0/0"
}

variable "enable_public_ip" {
  description = "Attach a public IP so the VM is directly SSH-reachable. Set false if you'll reach it via VPN/Bastion/peering instead."
  type        = bool
  default     = true
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB. Kept small to stay on the cheapest (Standard HDD) billing tier."
  type        = number
  default     = 30
}

variable "os_disk_type" {
  description = "OS disk storage type. Standard_LRS (HDD) is the cheapest option; use StandardSSD_LRS or Premium_LRS if you need better disk performance later."
  type        = string
  default     = "Standard_LRS"
}

variable "vnet_address_space" {
  description = "Address space for the VNet this VM's subnet lives in."
  type        = string
  default     = "10.20.0.0/24"
}

variable "subnet_prefix" {
  description = "Address prefix for the VM's subnet (must fall inside vnet_address_space)."
  type        = string
  default     = "10.20.0.0/26"
}
