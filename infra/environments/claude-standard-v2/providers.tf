terraform {
  required_version = ">= 1.11"

  # Run scripts/bootstrap-backend.sh --terraform-dir infra/environments/claude-standard-v2
  # before the first remote-state initialization.

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">= 2.11.0, < 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azapi" {}

data "azurerm_client_config" "current" {}
