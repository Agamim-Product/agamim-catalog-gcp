terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.81" }
  }
  # Bootstrap: the first apply runs with local state (it creates the state account itself), then
  # `terraform init -migrate-state` moves this state into the account it just created.
  backend "azurerm" {
    resource_group_name  = "rg-agamim-catalog-shared-ilc"
    storage_account_name = "agamimtfdc3eee23"
    container_name       = "tfstate"
    key                  = "shared.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}
