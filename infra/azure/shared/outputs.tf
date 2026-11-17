# Values to store as GitHub Environment variables (not secrets: OIDC needs no secret).
output "tenant_id" { value = azurerm_user_assigned_identity.planner.tenant_id }
output "deployer_client_ids" { value = { for k, v in azurerm_user_assigned_identity.deployer : k => v.client_id } }
output "planner_client_id" { value = azurerm_user_assigned_identity.planner.client_id }
output "state_account" { value = azurerm_storage_account.tfstate.name }
