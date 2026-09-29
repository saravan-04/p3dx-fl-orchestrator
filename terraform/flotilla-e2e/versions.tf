terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Auth comes from the caller's own `az login` session (or ARM_* env vars /
# a service principal). This is a single coordinated deployment (one
# subscription provisions the orchestrator + every data-provider VM), unlike
# terraform/participant-vm where each participant deploys independently.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
