terraform {
  required_version = ">= 1.5.0"

  # Declared explicitly (still just the default local backend - no `path`
  # set here) so vmAutoProvision.service.js can point a *copy* of this config
  # at one persistent state file per participant via `-backend-config`,
  # without a bare backend block `-backend-config` has nothing to configure.
  # deploy.sh's manual flow is unaffected: with no `path` override it behaves
  # exactly like the previously-implicit local backend.
  backend "local" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
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
