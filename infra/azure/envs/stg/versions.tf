terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.81" }
  }
  # State lives in the shared state account, signed in with Entra ID (no storage keys).
  backend "azurerm" {
    resource_group_name  = "rg-agamim-catalog-shared-ilc"
    storage_account_name = "agamimtfdc3eee23"
    container_name       = "tfstate"
    key                  = "stg.tfstate"
    use_azuread_auth     = true
  }
}

# subscription_id comes from ARM_SUBSCRIPTION_ID; sign-in from the Azure CLI locally or OIDC in CI.
provider "azurerm" {
  features {}
  storage_use_azuread = true
}
