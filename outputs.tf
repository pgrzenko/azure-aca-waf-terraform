###############################################################################
# outputs.tf
###############################################################################

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "app_gateway_public_ip" {
  description = "Public IP address of the Application Gateway (WAF entry point)"
  value       = azurerm_public_ip.agw.ip_address
}

output "app_gateway_public_ip_fqdn" {
  description = "DNS name of the Application Gateway public IP"
  value       = azurerm_public_ip.agw.fqdn
}

output "container_app_fqdn" {
  description = "Internal FQDN of the Container App (not directly reachable; route via AGW)"
  value       = azurerm_container_app.api.ingress[0].fqdn
}

output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for monitoring dashboards"
  value       = azurerm_log_analytics_workspace.main.id
}

output "container_app_environment_id" {
  description = "Container Apps Environment resource ID"
  value       = azurerm_container_app_environment.main.id
}

output "waf_policy_id" {
  description = "WAF Policy resource ID"
  value       = azurerm_web_application_firewall_policy.main.id
}
