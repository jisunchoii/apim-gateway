resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  location_key = lower(replace(replace(var.apim_location, " ", ""), "-", ""))
  region_short_map = {
    koreacentral = "krc"
  }
  region_short = lookup(local.region_short_map, local.location_key, substr(local.location_key, 0, 8))
  name_suffix  = "${var.prefix}-claude-${var.env}-${local.region_short}"

  tags = merge(
    var.tags,
    {
      env        = var.env
      workload   = "${var.prefix}-claude"
      generation = "standard-v2"
      owner      = var.owner
      costCenter = var.cost_center
    }
  )

  apim_name                 = "apim-${local.name_suffix}-${random_string.suffix.result}"
  claude_api_name           = "claude-gateway"
  claude_service_api_name   = "service-claude-gateway"
  claude_backend_id         = "databricks-claude"
  application_insights_name = "appi-${local.name_suffix}"
  log_analytics_name        = "log-${local.name_suffix}"
  resource_group_name       = "rg-${local.name_suffix}"
  workbook_name             = "workbook-${local.name_suffix}"
  databricks_workspace_url  = trimsuffix(var.databricks_claude_gateway.workspace_url, "/")
  databricks_backend_url    = "${local.databricks_workspace_url}/ai-gateway/anthropic"
  databricks_token_audience = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
  claude_model_prefixes     = ["system.ai.claude-opus-", "system.ai.claude-sonnet-", "system.ai.claude-haiku-", "system.ai.claude-fable-"]
  claude_model_prefixes_xml = join(", ", [for prefix in local.claude_model_prefixes : "&quot;${prefix}&quot;"])
  apim_gateway_url          = try(azapi_resource.apim.output.properties.gatewayUrl, "https://${local.apim_name}.azure-api.net")
  claude_gateway_base_url   = "${local.apim_gateway_url}/anthropic"
  claude_service_base_url   = "${local.apim_gateway_url}/service/anthropic"
  app_insights_logger_name  = "applicationinsights"
  azure_monitor_logger_name = "azuremonitor"
}
