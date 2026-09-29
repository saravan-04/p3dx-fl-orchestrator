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
# a service principal). Each participant runs this against their own
# subscription — nothing here assumes shared access.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
