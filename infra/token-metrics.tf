resource "azurerm_application_insights" "gateway" {
  name                                  = local.app_insights_name
  resource_group_name                   = azurerm_resource_group.rg.name
  location                              = azurerm_resource_group.rg.location
  workspace_id                          = azurerm_log_analytics_workspace.law.id
  application_type                      = "web"
  daily_data_cap_in_gb                  = 1
  daily_data_cap_notifications_enabled  = true
  local_authentication_enabled          = false
  tags                                  = local.tags
}

resource "azapi_update_resource" "application_insights_custom_metrics" {
  type        = "Microsoft.Insights/components@2020-02-02"
  resource_id = azurerm_application_insights.gateway.id

  body = {
    properties = {
      CustomMetricsOptedInType = "WithDimensions"
    }
  }
}

resource "azurerm_role_assignment" "apim_metrics_publisher" {
  scope                = azurerm_application_insights.gateway.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_api_management_logger" "application_insights" {
  name                = "applicationinsights"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  resource_id         = azurerm_application_insights.gateway.id
  buffered            = false
  description         = "Managed identity Application Insights logger for Classic gateway token metrics."

  application_insights {
    connection_string  = azurerm_application_insights.gateway.connection_string
    identity_client_id = "SystemAssigned"
  }

  depends_on = [
    azapi_update_resource.application_insights_custom_metrics,
    azurerm_role_assignment.apim_metrics_publisher,
  ]
}

locals {
  token_metric_api_ids = {
    user    = azurerm_api_management_api.gateway.id
    service = azurerm_api_management_api.service_gateway.id
  }
}

resource "azapi_resource" "application_insights_diagnostic" {
  for_each = local.token_metric_api_ids

  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2025-09-01-preview"
  name      = "applicationinsights"
  parent_id = each.value

  body = {
    properties = {
      loggerId                = azurerm_api_management_logger.application_insights.id
      alwaysLog               = "allErrors"
      httpCorrelationProtocol = "W3C"
      logClientIp             = false
      metrics                 = true
      verbosity               = "information"
      sampling = {
        samplingType = "fixed"
        percentage   = 100
      }
    }
  }
}
