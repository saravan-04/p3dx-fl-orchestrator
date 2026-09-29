variable "subscription_id" {
  description = "Azure subscription ID to deploy every VM into (orchestrator + all data providers, one coordinated apply). Leave null to use the subscription already selected via `az account set`."
  type        = string
  default     = null
}

variable "participant_name_prefix" {
  description = "Prefix used to name every VM this run creates: the orchestrator becomes \"<prefix>-orchestrator\", each data provider \"<prefix>-<name>\" for each entry in data_provider_names."
  type        = string
  default     = "flo-e2e"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,10}[a-z0-9])?$", var.participant_name_prefix))
    error_message = "participant_name_prefix must be 1-12 lowercase alphanumeric characters/dashes (kept short since it's combined with a role suffix under the 22-char participant_name limit)."
  }
}

variable "data_provider_names" {
  description = "Short, unique, lowercase-with-dashes names — one per data-provider VM to create. E.g. [\"dp1\", \"dp2\"] for a 2-client run."
  type        = list(string)
  default     = ["dp1"]

  validation {
    condition     = length(var.data_provider_names) > 0
    error_message = "data_provider_names must have at least one entry — a session needs at least one client."
  }
}

variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "centralindia"
}

variable "vm_size" {
  description = "VM size for every VM this run creates. See terraform/modules/flotilla-vm's variables.tf for why Standard_B2als_v2 (2 vCPU / 4 GiB) specifically."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "admin_username" {
  description = "Linux admin username created on every VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install on every VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the matching SSH private key, used by Terraform to provision each VM over SSH."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "flotilla_source_path" {
  description = "Local path to the Flotilla_Deployment checkout to copy onto every VM and build there."
  type        = string
  default     = "../../../Flotilla_Deployment"
}

variable "discovery_type" {
  description = "combine_fl discovery mechanism for both server and every client."
  type        = string
  default     = "grpc"
}

variable "image_tag" {
  description = "Tag for the locally-built flotilla-server/flotilla-client images."
  type        = string
  default     = "cpu"
}

variable "session_config_path" {
  description = "Session config (dataset/model/rounds) to POST to the server once all clients have connected. Defaults to the existing verified demo config (FedAT_CNN / CIFAR10_IID, 10 rounds — see Flotilla_Deployment/deployment/PROGRESS.md)."
  type        = string
  default     = "../../../Flotilla_Deployment/config/flotilla_quicksetup_config.yaml"
}

variable "wait_timeout_s" {
  description = "How long to wait for all data-provider clients to register with the server before giving up on starting the session."
  type        = number
  default     = 900
}

variable "gov_layer_url" {
  description = "Base URL (including /api/v1) of the p3dx governance layer's REST API, reachable from wherever `terraform apply` runs. Used only to register each VM's IP for visibility, not for the actual client->server wiring (which is passed directly through Terraform outputs, not looked up)."
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
  description = "CIDR allowed to reach port 22 on every VM."
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_fl_cidr" {
  description = "CIDR allowed to reach combine_fl's gRPC/REST ports on every VM."
  type        = string
  default     = "0.0.0.0/0"
}

variable "created_by" {
  description = "Identity running this deployment (e.g. from `az account show`). Stored as a tag on every VM. Optional."
  type        = string
  default     = null
}
