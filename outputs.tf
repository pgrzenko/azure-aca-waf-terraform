###############################################################################
# outputs.tf – Values exported after terraform apply
#
# These outputs serve two purposes:
# 1. Pipeline consumption: the CI/CD pipeline reads app_gateway_public_ip to
#    run the smoke test against the deployed infrastructure.
# 2. Operator reference: quick access to key identifiers without navigating
#    the Azure portal.
###############################################################################

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
  # Useful for ad-hoc az CLI commands: az resource list --resource-group <this>
}

output "app_gateway_public_ip" {
  description = "Public IP address of the Application Gateway (WAF entry point)"
  value       = azurerm_public_ip.agw.ip_address
  # This is the internet-facing entry point. The smoke test stage in the
  # pipeline curls this IP to verify end-to-end connectivity.
  # In production, create a DNS A record pointing to this IP.
}

output "app_gateway_public_ip_fqdn" {
  description = "DNS name of the Application Gateway public IP"
  value       = azurerm_public_ip.agw.fqdn
  # Azure-assigned FQDN (if domain label is configured). Null by default —
  # included here so it's available if a domain label is added later.
}

output "container_app_fqdn" {
  description = "Internal FQDN of the Container App (not directly reachable; route via AGW)"
  value       = azurerm_container_app.api.ingress[0].fqdn
  # This FQDN resolves only within the VNet. Exposed here for debugging —
  # you can curl it from a VM or Bastion host inside the VNet to bypass the WAF.
}

output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for monitoring dashboards"
  value       = azurerm_log_analytics_workspace.main.id
  # Needed when creating Kusto (KQL) queries or linking Azure Monitor workbooks
  # to this workspace.
}

output "container_app_environment_id" {
  description = "Container Apps Environment resource ID"
  value       = azurerm_container_app_environment.main.id
  # Required if adding more Container Apps to the same environment later —
  # they reference this ID in their container_app_environment_id attribute.
}

output "waf_policy_id" {
  description = "WAF Policy resource ID"
  value       = azurerm_web_application_firewall_policy.main.id
  # Useful for attaching the same policy to additional listeners or gateways.
}
