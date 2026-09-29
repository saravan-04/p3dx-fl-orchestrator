variable "role" {
  description = "Who this VM belongs to: \"data-provider\" or \"user\". Same convention as terraform/participant-vm — used for naming/tags and the gov_layer vm-registry entry."
  type        = string

  validation {
    condition     = contains(["data-provider", "user"], var.role)
    error_message = "role must be \"data-provider\" or \"user\"."
  }
}

variable "flotilla_workload" {
  description = "What Flotilla software to build and run on this VM: \"server\" (bundles server+redis+mosquitto, plus builds the session image, via docker-compose) or \"client\". Independent of `role` (which is only naming/gov_layer convention) so the two can't silently drift."
  type        = string

  validation {
    condition     = contains(["server", "client"], var.flotilla_workload)
    error_message = "flotilla_workload must be \"server\" or \"client\"."
  }
}

variable "participant_name" {
  description = "Short, unique, lowercase-with-dashes identifier for this participant, used in the VM name/tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,20}[a-z0-9])?$", var.participant_name))
    error_message = "participant_name must be 1-22 lowercase alphanumeric characters/dashes, and not start or end with a dash."
  }
}

variable "created_by" {
  description = "Identity that created this VM (e.g. from `az account show`). Stored as a tag for traceability. Optional."
  type        = string
  default     = null
}

variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Leave null to use the subscription already selected via `az account set`."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "centralindia"
}

variable "vm_size" {
  description = "VM size. Standard_B2als_v2 (2 vCPU / 4 GiB, burstable, AMD) is confirmed available in centralindia. Note this is tighter than terraform/participant-vm's bare-VM use case: this module actually builds torch-based Docker images and runs FL training on the box, so a build/session can be slow or memory-tight at 4 GiB — bump this if that becomes a problem (Standard_E2s_v5, 2 vCPU/16 GiB, is also confirmed available in this region)."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "admin_username" {
  description = "Linux admin username created on the VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install for admin_username."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the matching SSH private key, used locally by Terraform's file/remote-exec provisioners to reach the VM and copy the Flotilla source + run the build/start script over SSH."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "flotilla_source_path" {
  description = "Local path to the Flotilla_Deployment checkout whose src/, config/, deployment/, models/, and generate_dataset.py get copied to the VM and built there."
  type        = string
  default     = "../../../../Flotilla_Deployment"
}

variable "server_host" {
  description = "Address of the flotilla-server VM (its public IP), used as SERVER_GRPC_HOST when flotilla_workload = \"client\". Required in that case; ignored for \"server\"."
  type        = string
  default     = null
}

variable "discovery_type" {
  description = "combine_fl discovery mechanism both client and server must agree on."
  type        = string
  default     = "grpc"

  validation {
    condition     = contains(["grpc", "mqtt"], var.discovery_type)
    error_message = "discovery_type must be \"grpc\" or \"mqtt\"."
  }
}

variable "monitor" {
  description = "Passed as MONITOR to the client container's entrypoint (--monitor flag). Has no effect on the server, which hardcodes MONITOR=false in docker-compose.yaml."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Tag used for the locally-built flotilla-server/flotilla-client images (e.g. \"cpu\" or \"gpu\")."
  type        = string
  default     = "cpu"
}

variable "gov_layer_url" {
  description = "Base URL (including /api/v1) of the p3dx governance layer's REST API, reachable from wherever `terraform apply` runs — used only to register this VM's IP for visibility (see terraform/participant-vm's README). Not used to wire client->server here; that's passed directly via server_host."
  type        = string
  default     = "http://localhost:8083/api/v1"
}

variable "gov_layer_token" {
  description = "Shared secret sent as X-VM-Registry-Token to gov_layer's vm-registry endpoints. Leave blank if gov_layer doesn't have VM_REGISTRY_TOKEN set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22."
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_fl_cidr" {
  description = "CIDR allowed to reach combine_fl's gRPC ports (50051, 50052-50060) and, on the server, the REST API (12345)."
  type        = string
  default     = "0.0.0.0/0"
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB. A single flotilla-server or flotilla-client image (pytorch/pytorch base + torch/torchvision + deps) runs ~13-14 GiB on disk once built; 30 GiB leaves headroom for `docker build`'s intermediate layers plus the OS itself, but not much beyond that — watch `df -h` on the VM if you build/rebuild repeatedly."
  type        = number
  default     = 30
}

variable "os_disk_type" {
  description = "OS disk storage type. StandardSSD_LRS (not participant-vm's Standard_LRS HDD default) since this VM does real disk-heavy work: image builds and FL training I/O."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "vnet_address_space" {
  description = "Address space for the VNet this VM's subnet lives in. Every instance of this module gets its own isolated VNet (no peering between them), so this can safely default to the same range across all of them."
  type        = string
  default     = "10.20.0.0/24"
}

variable "subnet_prefix" {
  description = "Address prefix for the VM's subnet (must fall inside vnet_address_space)."
  type        = string
  default     = "10.20.0.0/26"
}
