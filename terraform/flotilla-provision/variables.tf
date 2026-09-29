variable "subscription_id" {
  description = "Azure subscription ID that already owns the orchestrator and data-provider VMs (created earlier via terraform/participant-vm). Leave null to use the subscription already selected via `az account set`."
  type        = string
  default     = null
}

variable "orchestrator_participant_name" {
  description = "participant_name of the already-created \"user\" VM (terraform/participant-vm's role=\"user\") to run the flotilla-server on — e.g. \"user1\" for a VM named flo-user-user1. Must already exist."
  type        = string
}

variable "data_provider_participant_names" {
  description = "participant_name of each already-created \"data-provider\" VM (terraform/participant-vm's role=\"data-provider\") to run a flotilla-client on — e.g. [\"data-provider5\"] for flo-data-provider-data-provider5. Each must already exist. Not looked up from gov_layer's vm-registry on purpose: that list accumulates stale entries for VMs that were later destroyed, so which VMs are actually live has to be told to this config explicitly."
  type        = list(string)

  validation {
    condition     = length(var.data_provider_participant_names) > 0
    error_message = "data_provider_participant_names must have at least one entry — a session needs at least one client."
  }
}

variable "flotilla_git_url" {
  description = "Git URL each VM clones the Flotilla_Deployment source from directly (no SSH/file-transfer from this machine needed — the VM pulls it itself over the internet via the Custom Script Extension)."
  type        = string
  default     = "https://github.com/datakaveri/Flotilla_Deployment.git"
}

variable "flotilla_git_ref" {
  description = "Branch/ref to clone."
  type        = string
  default     = "main"
}

variable "generate_dataset_script_path" {
  description = "Local path to generate_dataset.py — not committed to flotilla_git_url as of this writing, so its content is embedded directly into each VM's provisioning script instead of being cloned."
  type        = string
  default     = "../../../Flotilla_Deployment/generate_dataset.py"
}

variable "session_config_path" {
  description = "Session config (dataset/model/rounds) to run once all clients have connected. Defaults to the existing verified demo config (FedAT_CNN / CIFAR10_IID, 10 rounds — see Flotilla_Deployment/deployment/PROGRESS.md). Embedded directly into the orchestrator's start-session script."
  type        = string
  default     = "../../../Flotilla_Deployment/config/flotilla_quicksetup_config.yaml"
}

variable "discovery_type" {
  description = "combine_fl discovery mechanism for both server and every client."
  type        = string
  default     = "grpc"
}

variable "image_tag" {
  description = "Tag for the images each VM builds from source."
  type        = string
  default     = "cpu"
}

variable "wait_timeout_s" {
  description = "How long to wait for all data-provider clients to register with the server before giving up on starting the session."
  type        = number
  default     = 900
}

variable "allowed_fl_cidr" {
  description = "CIDR allowed to reach the orchestrator's REST API (12345) — this config adds that NSG rule to the orchestrator's existing security group (participant-vm's own NSG only opens 22/50051/50052-60, not 12345)."
  type        = string
  default     = "0.0.0.0/0"
}
