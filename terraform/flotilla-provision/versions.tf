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
# a service principal) — the same subscription that already owns the
# existing orchestrator/data-provider VMs this config targets.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
