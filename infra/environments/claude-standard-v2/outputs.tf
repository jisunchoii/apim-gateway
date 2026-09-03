output "resource_group_name" {
  description = "Resource group containing the Claude Standard v2 stack."
  value       = azurerm_resource_group.claude.name
}

output "apim_name" {
  description = "Korea Central Claude Standard v2 API Management name."
  value       = azapi_resource.apim.name
}

output "apim_resource_id" {
  description = "Claude Standard v2 API Management resource ID."
  value       = azapi_resource.apim.id
}

output "apim_managed_identity_principal_id" {
  description = "Object ID of the new APIM system-assigned managed identity."
  value       = azapi_resource.apim.output.identity.principalId
}

output "claude_gateway_base_url" {
  description = "Keycloak-authenticated Anthropic Messages base URL for Claude Code."
  value       = local.claude_gateway_base_url
}

output "claude_service_gateway_base_url" {
  description = "APIM subscription-authenticated Anthropic Messages base URL for service accounts."
  value       = local.claude_service_base_url
}

output "claude_gateway_models" {
  description = "Current Databricks Claude Opus, Sonnet, Haiku, and Fable defaults."
  value       = var.databricks_claude_gateway.models
}

output "databricks_workspace_url" {
  description = "Existing Azure Databricks workspace used by the Claude backend."
  value       = local.databricks_workspace_url
}

output "nat_gateway_public_ip" {
  description = "Static StandardV2 NAT public IP to allow in Databricks or Keycloak when IP restrictions are enabled."
  value       = azapi_resource.nat_public_ip.output.properties.ipAddress
}

output "log_analytics_workspace_id" {
  description = "Workspace GUID used by az monitor log-analytics query."
  value       = azurerm_log_analytics_workspace.claude.workspace_id
}

output "application_insights_resource_id" {
  description = "Workspace-based Application Insights resource used for APIM traces and token metrics."
  value       = azurerm_application_insights.claude.id
}

output "governance_workbook_url" {
  description = "Direct Azure portal URL for the Claude Standard v2 workbook."
  value = "https://portal.azure.com/#view/HubsExtension/ArgQueryBlade/query/${urlencode(
    "resources | where id =~ '${azapi_resource.workbook.id}'"
  )}"
}

output "catalog_outputs" {
  description = "Repository-relative Claude-only registry template and generated HTML paths."
  value       = var.catalog_outputs
}

output "api_catalog_manifest" {
  description = "Non-secret Claude-only catalog consumed by the generated registry HTML."
  value = {
    schema_version = 1
    gateway = {
      name                   = azapi_resource.apim.name
      generation             = "claude-standard-v2"
      tier                   = var.apim_sku
      location               = azurerm_resource_group.claude.location
      oidc_base_url          = local.claude_gateway_base_url
      service_base_url       = local.claude_service_base_url
      claude_base_url        = local.claude_gateway_base_url
      claude_model           = var.databricks_claude_gateway.models.sonnet
      claude_models          = var.databricks_claude_gateway.models
      nat_gateway_public_ip  = azapi_resource.nat_public_ip.output.properties.ipAddress
      token_metric_namespace = var.token_metric_namespace
    }
    backend_identity = {
      audience = local.databricks_token_audience
      role     = "Workspace-assigned Databricks service principal with system.ai model EXECUTE"
    }
    models = []
  }
}
