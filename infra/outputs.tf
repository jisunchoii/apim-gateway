output "gateway_base_url" {
  description = "OpenAI-compatible base_url. Point a supported client's OPENAI_BASE_URL here."
  value       = "${azurerm_api_management.apim.gateway_url}/openai/v1"
}

output "service_gateway_base_url" {
  description = "Subscription-authenticated OpenAI-compatible base URL for service accounts."
  value       = "${azurerm_api_management.apim.gateway_url}/service/openai/v1"
}

output "apim_public_ip_addresses" {
  description = "Classic gateway egress IPs allowed through the Azure AI Services firewall."
  value       = azurerm_api_management.apim.public_ip_addresses
}

output "foundry_account_name" {
  description = "Gateway-owned AIServices account name, or null when only existing project models are connected."
  value       = try(azurerm_cognitive_account.foundry["gateway"].name, null)
}

output "managed_foundry_account_enabled" {
  description = "Whether this stack currently creates a gateway-owned Foundry account."
  value       = local.managed_foundry_account_enabled
}

output "log_analytics_workspace_id" {
  description = "Workspace GUID for `az monitor log-analytics query -w`."
  value       = azurerm_log_analytics_workspace.law.workspace_id
}

output "oidc_audience" {
  description = "Audience APIM accepts in end-user access tokens."
  value       = var.oidc_provider.audience
}

output "oidc_openid_config_url" {
  description = "OIDC discovery document used by APIM and terminal token helpers."
  value       = var.oidc_provider.openid_config_url
}

output "oidc_client_id" {
  description = "Public Keycloak client ID used by terminal clients."
  value       = var.oidc_provider.client_id
}

output "oidc_client_scope" {
  description = "Scopes requested by terminal clients during device authorization."
  value       = var.oidc_provider.client_scope
}

output "oidc_required_scope" {
  description = "Scope required by the APIM validate-jwt policy."
  value       = var.oidc_provider.required_scope
}

output "oidc_role_claim" {
  description = "Access-token claim containing Keycloak Gateway client roles."
  value       = var.oidc_provider.role_claim
}

output "oidc_required_role" {
  description = "Keycloak client role required by the APIM validate-jwt policy."
  value       = var.oidc_provider.required_role
}

output "apim_name" {
  description = "API Management instance name for operational commands."
  value       = azurerm_api_management.apim.name
}

output "resource_group_name" {
  description = "Resource group holding the gateway."
  value       = azurerm_resource_group.rg.name
}

output "deployed_models" {
  description = "Managed and referenced model deployment names that currently have an APIM backend."
  value       = local.deployed_models
}

output "model_backend_ids" {
  description = "Deterministic APIM-safe backend IDs keyed by client-facing model name."
  value       = local.model_backend_ids
}

output "routed_models" {
  description = "Models currently referenced by the APIM gateway policy."
  value       = local.routed_models
}

output "opencode_model_config" {
  description = "OpenCode provider groups and defaults derived from each routed model's opencode_api."
  value = {
    responses_models = local.opencode_responses_models
    chat_models      = local.opencode_chat_models
    default_model    = coalesce(var.opencode_default_model, local.routed_models[0])
    small_model = coalesce(
      var.opencode_small_model,
      try(local.routed_models[1], local.routed_models[0])
    )
  }
}

output "api_catalog_manifest" {
  description = "Non-secret deployment catalog consumed by the generated Model Gateway Registry HTML."
  value = {
    schema_version = 1
    gateway = {
      name                 = azurerm_api_management.apim.name
      location             = azurerm_resource_group.rg.location
      oidc_base_url        = "${azurerm_api_management.apim.gateway_url}/openai/v1"
      service_base_url     = "${azurerm_api_management.apim.gateway_url}/service/openai/v1"
      foundry_account_name = try(azurerm_cognitive_account.foundry["gateway"].name, null)
    }
    backend_identity = {
      audience = "https://cognitiveservices.azure.com"
      role     = "Cognitive Services OpenAI User"
    }
    models = local.api_catalog_models
  }
}

output "trace_source" {
  description = "Source value emitted by the APIM trace policy and used by operational KQL."
  value       = local.trace_source
}

output "application_insights_resource_id" {
  description = "Workspace-based Application Insights resource used for Classic gateway token metrics."
  value       = azurerm_application_insights.gateway.id
}

output "governance_workbook_id" {
  description = "Resource ID of the Azure Monitor governance workbook."
  value       = azurerm_application_insights_workbook.governance.id
}

output "governance_workbook_portal_url" {
  description = "Direct Azure portal URL for the governance workbook."
  value       = "https://portal.azure.com/#@${data.azurerm_client_config.current.tenant_id}/resource${azurerm_application_insights_workbook.governance.id}"
}
