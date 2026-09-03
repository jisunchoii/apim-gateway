resource "azapi_resource" "apim" {
  type      = "Microsoft.ApiManagement/service@2024-05-01"
  name      = local.apim_name
  parent_id = azurerm_resource_group.claude.id
  location  = azurerm_resource_group.claude.location
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = {
      name     = var.apim_sku
      capacity = var.apim_capacity
    }
    properties = {
      publisherEmail      = var.apim_publisher_email
      publisherName       = var.apim_publisher_name
      publicNetworkAccess = "Enabled"
      virtualNetworkType  = "External"
      virtualNetworkConfiguration = {
        subnetResourceId = azurerm_subnet.apim.id
      }
    }
  }

  response_export_values = [
    "identity.principalId",
    "properties.gatewayUrl",
  ]

  depends_on = [
    azurerm_subnet_nat_gateway_association.apim,
    azurerm_subnet_network_security_group_association.apim,
  ]
}

resource "azurerm_api_management_backend" "claude" {
  name                = local.claude_backend_id
  resource_group_name = azurerm_resource_group.claude.name
  api_management_name = azapi_resource.apim.name
  protocol            = "http"
  url                 = local.databricks_backend_url
}

resource "azurerm_api_management_api" "claude" {
  name                = local.claude_api_name
  resource_group_name = azurerm_resource_group.claude.name
  api_management_name = azapi_resource.apim.name
  revision            = "1"
  display_name        = "Claude Gateway"
  path                = "anthropic"
  protocols           = ["https"]

  subscription_required = false
}

resource "azurerm_api_management_api" "claude_service" {
  name                = local.claude_service_api_name
  resource_group_name = azurerm_resource_group.claude.name
  api_management_name = azapi_resource.apim.name
  revision            = "1"
  display_name        = "Claude Service Gateway"
  path                = "service/anthropic"
  protocols           = ["https"]

  subscription_required = true
}

resource "azurerm_api_management_api_operation" "messages" {
  operation_id        = "claude-messages"
  api_name            = azurerm_api_management_api.claude.name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.claude.name
  display_name        = "Claude Messages"
  method              = "POST"
  url_template        = "/v1/messages"
}

resource "azurerm_api_management_api_operation" "service_messages" {
  operation_id        = "claude-messages"
  api_name            = azurerm_api_management_api.claude_service.name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.claude.name
  display_name        = "Claude Messages"
  method              = "POST"
  url_template        = "/v1/messages"
}

locals {
  claude_policy_parameters = {
    backend_id                = azurerm_api_management_backend.claude.name
    claude_model_prefixes     = local.claude_model_prefixes_xml
    oidc_openid_config_url    = var.oidc_provider.openid_config_url
    oidc_audience             = var.oidc_provider.audience
    oidc_issuer               = var.oidc_provider.issuer
    oidc_required_scope       = var.oidc_provider.required_scope
    oidc_scope_claim          = var.oidc_provider.scope_claim
    oidc_role_claim           = var.oidc_provider.role_claim
    oidc_required_role        = var.oidc_provider.required_role
    oidc_user_label_claim     = var.oidc_provider.user_label_claim
    databricks_token_audience = local.databricks_token_audience
    token_metric_namespace    = var.token_metric_namespace
    trace_source              = var.trace_source
    user_token_limit          = var.user_tokens_per_minute
  }
}

resource "azurerm_api_management_api_policy" "claude" {
  api_name            = azurerm_api_management_api.claude.name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.claude.name

  xml_content = templatefile(
    "${path.module}/../../../policies/claude-standard-v2-gateway.xml.tftpl",
    merge(local.claude_policy_parameters, { authentication_mode = "oidc" })
  )

  depends_on = [
    azurerm_api_management_api_operation.messages,
    azapi_resource.application_insights_diagnostic,
    azapi_resource.azure_monitor_diagnostic,
  ]
}

resource "azurerm_api_management_api_policy" "claude_service" {
  api_name            = azurerm_api_management_api.claude_service.name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.claude.name

  xml_content = templatefile(
    "${path.module}/../../../policies/claude-standard-v2-gateway.xml.tftpl",
    merge(local.claude_policy_parameters, { authentication_mode = "subscription" })
  )

  depends_on = [
    azurerm_api_management_api_operation.service_messages,
    azapi_resource.service_application_insights_diagnostic,
    azapi_resource.service_azure_monitor_diagnostic,
  ]
}
