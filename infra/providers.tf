terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.11.0, < 3.0.0"
    }
  }

  # 기존 배포는 local state를 유지한다. 신규 배포는 scripts/bootstrap-backend.sh가
  # ignore된 backend.tf를 생성한 뒤 Azure Blob backend로 초기화한다.
}

provider "azurerm" {
  storage_use_azuread = true
  features {}
}

provider "azapi" {}
