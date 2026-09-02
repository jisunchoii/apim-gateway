resource "azurerm_log_analytics_workspace" "claude" {
  name                = local.log_analytics_name
  resource_group_name = azurerm_resource_group.claude.name
  location            = azurerm_resource_group.claude.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_application_insights" "claude" {
  name                         = local.application_insights_name
  resource_group_name          = azurerm_resource_group.claude.name
  location                     = azurerm_resource_group.claude.location
  workspace_id                 = azurerm_log_analytics_workspace.claude.id
  application_type             = "web"
  retention_in_days            = var.log_retention_days
  sampling_percentage          = 100
  internet_ingestion_enabled   = true
  internet_query_enabled       = true
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azapi_update_resource" "application_insights_custom_metrics" {
  type        = "Microsoft.Insights/components@2020-02-02"
  resource_id = azurerm_application_insights.claude.id

  body = {
    properties = {
      CustomMetricsOptedInType = "WithDimensions"
    }
  }
}

resource "azurerm_role_assignment" "apim_metrics_publisher" {
  scope                = azurerm_application_insights.claude.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azapi_resource.apim.output.identity.principalId
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                           = "resource-logs"
  target_resource_id             = azapi_resource.apim.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.claude.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_log {
    category = "GatewayLlmLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azapi_update_resource" "azure_monitor_logger" {
  type        = "Microsoft.ApiManagement/service/loggers@2025-09-01-preview"
  resource_id = "${azapi_resource.apim.id}/loggers/${local.azure_monitor_logger_name}"

  body = {
    properties = {
      loggerType  = "azureMonitor"
      isBuffered  = false
      description = "Azure Monitor logger for Claude gateway and LLM token diagnostics."
    }
  }
}

resource "azapi_resource" "azure_monitor_diagnostic" {
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2025-09-01-preview"
  name      = local.azure_monitor_logger_name
  parent_id = azurerm_api_management_api.claude.id

  body = {
    properties = {
      loggerId    = azapi_update_resource.azure_monitor_logger.id
      alwaysLog   = "allErrors"
      logClientIp = false
      verbosity   = "information"
      sampling = {
        samplingType = "fixed"
        percentage   = 100
      }
      largeLanguageModel = {
        logs = "enabled"
      }
    }
  }

  depends_on = [azurerm_monitor_diagnostic_setting.apim]
}

resource "azurerm_api_management_logger" "application_insights" {
  name                = local.app_insights_logger_name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.claude.name
  resource_id         = azurerm_application_insights.claude.id
  buffered            = false
  description         = "Managed identity Application Insights logger for Claude token metrics and traces."

  application_insights {
    connection_string  = azurerm_application_insights.claude.connection_string
    identity_client_id = "SystemAssigned"
  }

  depends_on = [
    azapi_update_resource.application_insights_custom_metrics,
    azurerm_role_assignment.apim_metrics_publisher,
  ]
}

resource "azapi_resource" "application_insights_diagnostic" {
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2025-09-01-preview"
  name      = local.app_insights_logger_name
  parent_id = azurerm_api_management_api.claude.id

  body = {
    properties = {
      loggerId                = azurerm_api_management_logger.application_insights.id
      alwaysLog               = "allErrors"
      httpCorrelationProtocol = "W3C"
      logClientIp             = false
      metrics                 = true
      operationNameFormat     = "Name"
      verbosity               = "information"
      sampling = {
        samplingType = "fixed"
        percentage   = 100
      }
      frontend = {
        request = {
          body = {
            bytes = 0
          }
          headers = []
        }
        response = {
          body = {
            bytes = 0
          }
          headers = []
        }
      }
      backend = {
        request = {
          body = {
            bytes = 0
          }
          headers = []
        }
        response = {
          body = {
            bytes = 0
          }
          headers = []
        }
      }
    }
  }
}

locals {
  claude_governance_models = values(var.databricks_claude_gateway.models)

  claude_governance_price_rows = join(", ", [
    for model_name in local.claude_governance_models :
    "  ${jsonencode(model_name)}, ${jsonencode(try(var.model_pricing_dbu_per_million[model_name].input, 0))}, ${jsonencode(try(var.model_pricing_dbu_per_million[model_name].output, 0))}, ${jsonencode(try(var.model_pricing_dbu_per_million[model_name].cached_input, 0))}"
  ])

  claude_governance_pricing_summary = join(" · ", [
    for model_name in local.claude_governance_models :
    "${model_name}: input ${try(var.model_pricing_dbu_per_million[model_name].input, 0)}, output ${try(var.model_pricing_dbu_per_million[model_name].output, 0)}, cached input ${try(var.model_pricing_dbu_per_million[model_name].cached_input, 0)} DBU/1M"
  ])

  claude_governance_base_query = <<-KQL
    let ModelPrices = datatable(Model:string, InputDbuPerMillion:real, OutputDbuPerMillion:real, CachedInputDbuPerMillion:real) [ ${local.claude_governance_price_rows} ];
    let IdentityEvents = materialize(
        AppTraces
        | where TimeGenerated {TimeRange}
        | where Message startswith '{"event":"claude_gateway_request"'
        | extend Payload = parse_json(Message)
        | project
            IdentityTime = TimeGenerated,
            CorrelationId = tostring(Payload.correlationId),
            UserHash = tostring(Payload.userHash),
            UserLabel = tostring(Payload.userLabel),
            RequestedModel = tostring(Payload.requestedModel),
            SubscriptionId = tostring(Payload.subscriptionId),
            SubscriptionName = tostring(Payload.subscriptionName)
        | summarize arg_max(IdentityTime, *) by CorrelationId
    );
    let UserDirectory = materialize(
        IdentityEvents
        | where isnotempty(UserHash)
        | summarize arg_max(IdentityTime, UserLabel) by UserHash
        | project UserHash, UserLabel
    );
    let Gateway = materialize(
        ApiManagementGatewayLogs
        | where TimeGenerated {TimeRange}
        | where ApiId == "${local.claude_api_name}" and OperationId == "claude-messages"
        | summarize arg_max(TimeGenerated, *) by CorrelationId
        | project
            RequestTime = TimeGenerated,
            CorrelationId,
            LoggedSubscriptionId = tostring(ApimSubscriptionId),
            ResponseCode = toint(ResponseCode),
            BackendResponseCode = toint(BackendResponseCode),
            TotalTimeMs = todouble(TotalTime),
            BackendTimeMs = todouble(BackendTime),
            LastErrorReason = tostring(LastErrorReason)
        | join kind=leftouter IdentityEvents on CorrelationId
        | extend
            UserHash = iff(isempty(UserHash), "unknown", UserHash),
            UserLabel = iff(isempty(UserLabel), iff(UserHash == "unknown", "unknown", substring(UserHash, 0, 12)), UserLabel),
            RequestedModel = iff(isempty(RequestedModel), "unknown", RequestedModel),
            SubscriptionId = iff(
                isempty(SubscriptionId),
                iff(isempty(LoggedSubscriptionId), "none", LoggedSubscriptionId),
                SubscriptionId
            ),
            SubscriptionName = iff(isempty(SubscriptionName), "none", SubscriptionName)
    );
    let RequestTokens = materialize(
        ApiManagementGatewayLlmLog
        | where TimeGenerated {TimeRange}
        | summarize arg_max(TimeGenerated, *) by CorrelationId
        | project
            CorrelationId,
            PromptTokens = tolong(PromptTokens),
            CompletionTokens = tolong(CompletionTokens),
            TotalTokens = tolong(TotalTokens),
            ModelName = tostring(ModelName),
            DeploymentName = tostring(DeploymentName),
            IsStreamCompletion = tobool(IsStreamCompletion)
    );
    let Requests = materialize(
        Gateway
        | join kind=leftouter RequestTokens on CorrelationId
        | extend
            Model = iff(
                isnotempty(DeploymentName),
                DeploymentName,
                iff(isnotempty(ModelName), ModelName, RequestedModel)
            ),
            PromptTokens = coalesce(PromptTokens, tolong(0)),
            CompletionTokens = coalesce(CompletionTokens, tolong(0)),
            TotalTokens = coalesce(TotalTokens, tolong(0)),
            IsSuccess = ResponseCode between (200 .. 299)
    );
    let MetricRows = materialize(
        AppMetrics
        | where TimeGenerated {TimeRange}
        | where Name in ("Prompt Tokens", "Prompt Cached Tokens", "Completion Tokens")
        | extend Dimensions = todynamic(Properties)
        | project
            MetricTime = TimeGenerated,
            MetricName = Name,
            TokenValue = tolong(Sum),
            Model = tostring(Dimensions.Model),
            UserHash = tostring(Dimensions["User Hash"]),
            SubscriptionId = tostring(Dimensions["Subscription ID"]),
            SubscriptionName = tostring(Dimensions["Subscription Name"])
        | extend
            Model = iff(isempty(Model), "unknown", Model),
            UserHash = iff(isempty(UserHash), "unknown", UserHash),
            SubscriptionId = iff(isempty(SubscriptionId), "none", SubscriptionId),
            SubscriptionName = iff(isempty(SubscriptionName), "none", SubscriptionName)
    );
    let Usage = materialize(
        MetricRows
        | summarize
            UncachedInputTokens = sumif(TokenValue, MetricName == "Prompt Tokens"),
            CachedInputTokens = sumif(TokenValue, MetricName == "Prompt Cached Tokens"),
            OutputTokens = sumif(TokenValue, MetricName == "Completion Tokens")
          by UserHash, SubscriptionId, SubscriptionName, Model
        | join kind=leftouter UserDirectory on UserHash
        | join kind=leftouter ModelPrices on Model
        | extend
            UserLabel = iff(isempty(UserLabel), iff(UserHash == "unknown", "unknown", substring(UserHash, 0, 12)), UserLabel),
            InputDbuPerMillion = coalesce(InputDbuPerMillion, 0.0),
            OutputDbuPerMillion = coalesce(OutputDbuPerMillion, 0.0),
            CachedInputDbuPerMillion = coalesce(CachedInputDbuPerMillion, 0.0)
        | extend
            ObservedTokens = UncachedInputTokens + CachedInputTokens + OutputTokens,
            CacheHitPct = iff(
                UncachedInputTokens + CachedInputTokens == 0,
                0.0,
                round(100.0 * todouble(CachedInputTokens) / todouble(UncachedInputTokens + CachedInputTokens), 2)
            ),
            EstimatedDbu =
                todouble(UncachedInputTokens) * InputDbuPerMillion / 1000000.0
                + todouble(CachedInputTokens) * CachedInputDbuPerMillion / 1000000.0
                + todouble(OutputTokens) * OutputDbuPerMillion / 1000000.0,
            IsPriceConfigured =
                InputDbuPerMillion > 0.0
                or OutputDbuPerMillion > 0.0
                or CachedInputDbuPerMillion > 0.0
        | extend EstimatedCostUsd = EstimatedDbu * ${var.databricks_dbu_price_usd}
    );
  KQL

  claude_governance_query_common = {
    version                  = "KqlItem/1.0"
    size                     = 1
    timeContext              = { durationMs = 0 }
    timeContextFromParameter = "TimeRange"
    queryType                = 0
    resourceType             = "microsoft.operationalinsights/workspaces"
    crossComponentResources  = [azurerm_log_analytics_workspace.claude.id]
    showAnalytics            = true
    showExportToExcel        = true
  }

  claude_governance_grid_settings = {
    filter = true
  }

  claude_governance_tile_settings = {
    titleContent = {
      columnMatch = "Metric"
      formatter   = 1
    }
    leftContent = {
      columnMatch = "Value"
      formatter   = 12
      formatOptions = {
        showIcon = true
      }
    }
    showBorder = true
  }

  claude_governance_workbook_data = {
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "introduction"
        content = {
          json = <<-MARKDOWN
            # Claude Standard v2 Governance

            Keycloak 사용자, APIM subscription, Claude 모델별 요청·token·cached input·비용·오류·지연을 확인합니다.
            사용자 집계 키는 `iss:sub` SHA-256 hash이며 raw APIM subscription key와 prompt/completion 본문은 저장하지 않습니다.

            **모델 DBU 입력:** ${local.claude_governance_pricing_summary}

            **DBU 단가:** ${var.databricks_dbu_price_usd} USD/DBU. 비용은 운영 추정치이며 Azure 청구서가 아닙니다.
          MARKDOWN
        }
      },
      {
        type = 9
        name = "parameters"
        content = {
          version = "KqlParameterItem/1.0"
          parameters = [
            {
              id         = "claude-governance-time-range"
              version    = "KqlParameterItem/1.0"
              name       = "TimeRange"
              label      = "Time range"
              type       = 4
              isRequired = true
              value      = { durationMs = 604800000 }
              typeSettings = {
                selectableValues = [
                  { durationMs = 3600000 },
                  { durationMs = 14400000 },
                  { durationMs = 43200000 },
                  { durationMs = 86400000 },
                  { durationMs = 172800000 },
                  { durationMs = 604800000 },
                  { durationMs = 1209600000 },
                  { durationMs = 2592000000 }
                ]
                allowCustom = true
              }
            }
          ]
          style        = "pills"
          queryType    = 0
          resourceType = "microsoft.operationalinsights/workspaces"
        }
      },
      {
        type = 1
        name = "overview-heading"
        content = {
          json = "## Overview\n사용자·구독·요청·token·cached input·추정 비용과 성공률을 요약합니다."
        }
      },
      {
        type = 3
        name = "overview-kpis"
        content = merge(local.claude_governance_query_common, {
          title         = "Key indicators"
          visualization = "tiles"
          tileSettings  = local.claude_governance_tile_settings
          query         = <<-KQL
            ${local.claude_governance_base_query}
            union
                (Requests
                 | summarize Value = todouble(dcountif(UserHash, UserHash != "unknown"))
                 | extend SortOrder = 1, Metric = "Active users"),
                (Requests
                 | summarize Value = todouble(dcountif(SubscriptionId, SubscriptionId != "none"))
                 | extend SortOrder = 2, Metric = "Active subscriptions"),
                (Requests
                 | summarize Value = todouble(count())
                 | extend SortOrder = 3, Metric = "Requests"),
                (Usage
                 | summarize Value = todouble(sum(UncachedInputTokens))
                 | extend SortOrder = 4, Metric = "Uncached input tokens"),
                (Usage
                 | summarize Value = todouble(sum(CachedInputTokens))
                 | extend SortOrder = 5, Metric = "Cached input tokens"),
                (Usage
                 | summarize Value = todouble(sum(OutputTokens))
                 | extend SortOrder = 6, Metric = "Output tokens"),
                (Usage
                 | summarize Value = todouble(sum(ObservedTokens))
                 | extend SortOrder = 7, Metric = "Observed billable tokens"),
                (Usage
                 | summarize Value = round(sum(EstimatedDbu), 6)
                 | extend SortOrder = 8, Metric = "Estimated DBU"),
                (Usage
                 | summarize Value = round(sum(EstimatedCostUsd), 6)
                 | extend SortOrder = 9, Metric = "Estimated cost (USD)"),
                (Usage
                 | summarize Uncached = sum(UncachedInputTokens), Cached = sum(CachedInputTokens)
                 | extend Value = iff(Uncached + Cached == 0, 0.0, round(100.0 * todouble(Cached) / todouble(Uncached + Cached), 2))
                 | extend SortOrder = 10, Metric = "Cached input share (%)"),
                (Requests
                 | summarize Total = count(), Successful = countif(IsSuccess)
                 | extend Value = iff(Total == 0, 0.0, round(100.0 * todouble(Successful) / todouble(Total), 2))
                 | extend SortOrder = 11, Metric = "Success rate (%)"),
                (Requests
                 | summarize Value = round(percentile(TotalTimeMs, 95), 0)
                 | extend SortOrder = 12, Metric = "End-to-end p95 (ms)")
            | project SortOrder, Metric, Value
            | order by SortOrder asc
          KQL
        })
      },
      {
        type        = 3
        name        = "traffic-health"
        customWidth = "50"
        content = merge(local.claude_governance_query_common, {
          title         = "Traffic and failures"
          visualization = "timechart"
          query         = <<-KQL
            ${local.claude_governance_base_query}
            let Grain = {TimeRange:grain};
            Requests
            | summarize
                Requests = count(),
                Successful = countif(IsSuccess),
                ClientErrors = countif(ResponseCode between (400 .. 499)),
                ServerErrors = countif(ResponseCode >= 500)
              by TimeGenerated = bin(RequestTime, Grain)
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type        = 3
        name        = "token-volume"
        customWidth = "50"
        content = merge(local.claude_governance_query_common, {
          title         = "Token volume including cached input"
          visualization = "timechart"
          query         = <<-KQL
            ${local.claude_governance_base_query}
            let Grain = {TimeRange:grain};
            MetricRows
            | summarize Value = sum(TokenValue)
              by TimeGenerated = bin(MetricTime, Grain), Series = strcat(Model, " / ", MetricName)
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type = 3
        name = "model-usage-cost"
        content = merge(local.claude_governance_query_common, {
          title        = "Model token usage and estimated cost"
          gridSettings = local.claude_governance_grid_settings
          query        = <<-KQL
            ${local.claude_governance_base_query}
            Usage
            | where Model != "unknown"
            | summarize
                ActiveUsers = dcountif(UserHash, UserHash != "unknown"),
                ActiveSubscriptions = dcountif(SubscriptionId, SubscriptionId != "none"),
                UncachedInputTokens = sum(UncachedInputTokens),
                CachedInputTokens = sum(CachedInputTokens),
                OutputTokens = sum(OutputTokens),
                ObservedTokens = sum(ObservedTokens),
                EstimatedDbu = round(sum(EstimatedDbu), 6),
                EstimatedCostUsd = round(sum(EstimatedCostUsd), 6),
                PriceConfiguredRows = countif(IsPriceConfigured)
              by Model
            | extend
                CachedInputSharePct = iff(
                    UncachedInputTokens + CachedInputTokens == 0,
                    0.0,
                    round(100.0 * todouble(CachedInputTokens) / todouble(UncachedInputTokens + CachedInputTokens), 2)
                ),
                Pricing = iff(PriceConfiguredRows > 0, "configured", "zero/unset")
            | project Model, ActiveUsers, ActiveSubscriptions, UncachedInputTokens, CachedInputTokens,
                CachedInputSharePct, OutputTokens, ObservedTokens, EstimatedDbu, EstimatedCostUsd, Pricing
            | order by ObservedTokens desc
          KQL
        })
      },
      {
        type = 1
        name = "users-heading"
        content = {
          json = "## Users and subscriptions\nKeycloak 사용자 hash/label과 APIM subscription ID/name별 token 및 비용을 확인합니다. 현재 key 없는 요청은 subscription `none`으로 표시됩니다."
        }
      },
      {
        type = 3
        name = "user-detail"
        content = merge(local.claude_governance_query_common, {
          title        = "User and subscription usage"
          gridSettings = local.claude_governance_grid_settings
          query        = <<-KQL
            ${local.claude_governance_base_query}
            let RequestSummary =
                Requests
                | summarize
                    Requests = count(),
                    Successful = countif(IsSuccess),
                    RateLimited429 = countif(ResponseCode == 429),
                    Forbidden403 = countif(ResponseCode == 403),
                    ServerErrors = countif(ResponseCode >= 500),
                    P95LatencyMs = round(percentile(TotalTimeMs, 95), 0),
                    LastSeen = max(RequestTime)
                  by UserHash, SubscriptionId;
            Usage
            | summarize
                User = any(UserLabel),
                Subscription = any(SubscriptionName),
                Models = strcat_array(make_set(Model, 10), ", "),
                UncachedInputTokens = sum(UncachedInputTokens),
                CachedInputTokens = sum(CachedInputTokens),
                OutputTokens = sum(OutputTokens),
                ObservedTokens = sum(ObservedTokens),
                EstimatedDbu = round(sum(EstimatedDbu), 6),
                EstimatedCostUsd = round(sum(EstimatedCostUsd), 6)
              by UserHash, SubscriptionId
            | join kind=leftouter RequestSummary on UserHash, SubscriptionId
            | extend
                CachedInputSharePct = iff(
                    UncachedInputTokens + CachedInputTokens == 0,
                    0.0,
                    round(100.0 * todouble(CachedInputTokens) / todouble(UncachedInputTokens + CachedInputTokens), 2)
                ),
                SuccessRatePct = iff(Requests == 0, 0.0, round(100.0 * todouble(Successful) / todouble(Requests), 2))
            | project User, UserHash, Subscription, SubscriptionId, Requests, UncachedInputTokens,
                CachedInputTokens, CachedInputSharePct, OutputTokens, ObservedTokens, EstimatedDbu,
                EstimatedCostUsd, SuccessRatePct, P95LatencyMs, RateLimited429, Forbidden403,
                ServerErrors, Models, LastSeen
            | order by ObservedTokens desc
          KQL
        })
      },
      {
        type        = 3
        name        = "top-users"
        customWidth = "50"
        content = merge(local.claude_governance_query_common, {
          title         = "Top users by estimated cost"
          visualization = "barchart"
          query         = <<-KQL
            ${local.claude_governance_base_query}
            Usage
            | where UserHash != "unknown"
            | summarize EstimatedCostUsd = round(sum(EstimatedCostUsd), 6), User = any(UserLabel) by UserHash
            | top 10 by EstimatedCostUsd desc
            | project User, EstimatedCostUsd
          KQL
        })
      },
      {
        type        = 3
        name        = "top-subscriptions"
        customWidth = "50"
        content = merge(local.claude_governance_query_common, {
          title         = "Top subscriptions by estimated cost"
          visualization = "barchart"
          query         = <<-KQL
            ${local.claude_governance_base_query}
            Usage
            | summarize
                EstimatedCostUsd = round(sum(EstimatedCostUsd), 6),
                Subscription = any(SubscriptionName)
              by SubscriptionId
            | top 10 by EstimatedCostUsd desc
            | project Subscription = iff(SubscriptionId == "none", "none", Subscription), SubscriptionId, EstimatedCostUsd
          KQL
        })
      },
      {
        type = 3
        name = "subscription-detail"
        content = merge(local.claude_governance_query_common, {
          title        = "Subscription usage and estimated cost"
          gridSettings = local.claude_governance_grid_settings
          query        = <<-KQL
            ${local.claude_governance_base_query}
            Usage
            | summarize
                Subscription = any(SubscriptionName),
                ActiveUsers = dcountif(UserHash, UserHash != "unknown"),
                Models = strcat_array(make_set(Model, 10), ", "),
                UncachedInputTokens = sum(UncachedInputTokens),
                CachedInputTokens = sum(CachedInputTokens),
                OutputTokens = sum(OutputTokens),
                ObservedTokens = sum(ObservedTokens),
                EstimatedDbu = round(sum(EstimatedDbu), 6),
                EstimatedCostUsd = round(sum(EstimatedCostUsd), 6)
              by SubscriptionId
            | extend CachedInputSharePct = iff(
                UncachedInputTokens + CachedInputTokens == 0,
                0.0,
                round(100.0 * todouble(CachedInputTokens) / todouble(UncachedInputTokens + CachedInputTokens), 2)
              )
            | project Subscription, SubscriptionId, ActiveUsers, UncachedInputTokens, CachedInputTokens,
                CachedInputSharePct, OutputTokens, ObservedTokens, EstimatedDbu, EstimatedCostUsd, Models
            | order by ObservedTokens desc
          KQL
        })
      },
      {
        type = 1
        name = "operations-heading"
        content = {
          json = "## Reliability and capacity\n모델별 성공률·오류·지연과 APIM Standard v2 platform metrics를 확인합니다."
        }
      },
      {
        type = 3
        name = "model-health"
        content = merge(local.claude_governance_query_common, {
          title        = "Model health and latency"
          gridSettings = local.claude_governance_grid_settings
          query        = <<-KQL
            ${local.claude_governance_base_query}
            Requests
            | summarize
                Requests = count(),
                Successful = countif(IsSuccess),
                ClientErrors = countif(ResponseCode between (400 .. 499)),
                ServerErrors = countif(ResponseCode >= 500),
                RateLimited429 = countif(ResponseCode == 429),
                P50LatencyMs = round(percentile(TotalTimeMs, 50), 0),
                P95LatencyMs = round(percentile(TotalTimeMs, 95), 0),
                P99LatencyMs = round(percentile(TotalTimeMs, 99), 0),
                P95BackendMs = round(percentile(BackendTimeMs, 95), 0)
              by Model
            | extend SuccessRatePct = iff(Requests == 0, 0.0, round(100.0 * todouble(Successful) / todouble(Requests), 2))
            | project Model, Requests, SuccessRatePct, ClientErrors, ServerErrors, RateLimited429,
                P50LatencyMs, P95LatencyMs, P99LatencyMs, P95BackendMs
            | order by Requests desc
          KQL
        })
      },
      {
        type = 3
        name = "error-reasons"
        content = merge(local.claude_governance_query_common, {
          title        = "Top error reasons"
          gridSettings = local.claude_governance_grid_settings
          query        = <<-KQL
            ${local.claude_governance_base_query}
            Requests
            | where ResponseCode >= 400
            | extend Reason = iff(isempty(LastErrorReason), "policy/client/backend response", LastErrorReason)
            | summarize
                Errors = count(),
                AffectedUsers = dcountif(UserHash, UserHash != "unknown"),
                AffectedSubscriptions = dcountif(SubscriptionId, SubscriptionId != "none"),
                LastSeen = max(RequestTime)
              by ResponseCode, BackendResponseCode, Reason, Model
            | top 30 by Errors desc
          KQL
        })
      },
      {
        type = 10
        name = "apim-resource-metrics"
        content = {
          chartId                  = "claude-apim-resource-metrics"
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.apimanagement/service"
          metricScope              = 0
          resourceIds              = [azapi_resource.apim.id]
          timeContext              = { durationMs = 0 }
          timeContextFromParameter = "TimeRange"
          metrics = [
            {
              namespace   = "microsoft.apimanagement/service"
              metric      = "microsoft.apimanagement/service-Capacity-Capacity"
              aggregation = 4
              splitBy     = null
              columnName  = "APIM capacity (%)"
            },
            {
              namespace   = "microsoft.apimanagement/service"
              metric      = "microsoft.apimanagement/service-Capacity-CpuPercent_Gateway"
              aggregation = 4
              splitBy     = null
              columnName  = "Gateway CPU (%)"
            },
            {
              namespace   = "microsoft.apimanagement/service"
              metric      = "microsoft.apimanagement/service-Capacity-MemoryPercent_Gateway"
              aggregation = 4
              splitBy     = null
              columnName  = "Gateway memory (%)"
            }
          ]
          title         = "APIM capacity, CPU, and memory"
          resourceLimit = 10
          filters       = []
        }
      },
      {
        type = 1
        name = "notes"
        content = {
          json = <<-MARKDOWN
            ---
            **해석 주의**

            * `Prompt Cached Tokens`는 Databricks response의 `cache_read_input_tokens`에 해당하며 cached input 단가로 계산합니다.
            * 현재 APIM preview metric은 `cache_creation_input_tokens`를 별도 cache-write metric으로 내보내지 않으므로 추정 DBU/USD에는 cache write 비용이 포함되지 않습니다.
            * Keycloak-only 요청은 APIM subscription이 없으므로 `SubscriptionId=none`으로 집계됩니다. 유효한 APIM subscription이 연결된 요청만 subscription별로 분리됩니다.
            * raw subscription key, JWT subject, prompt와 completion 본문은 저장하지 않습니다.
            * APIM custom metric은 dimension당 최대 100개 값과 namespace당 최대 1,000 active time series 제한이 있어 사용자 수가 커지면 별도 telemetry pipeline이 필요합니다.
            * 스트리밍 요청이 중간 취소되면 usage와 token metric이 누락되거나 부정확할 수 있습니다.
            * `Estimated cost`는 Terraform의 DBU 소비율과 ${var.databricks_dbu_price_usd} USD/DBU를 사용한 운영 추정치이며 Azure 청구서가 아닙니다.
          MARKDOWN
        }
      }
    ]
    styleSettings = {
      spacingStyle = "wide"
    }
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  }
}

resource "azapi_resource" "workbook" {
  type      = "Microsoft.Insights/workbooks@2023-06-01"
  name      = uuidv5("url", "${azapi_resource.apim.id}/claude-standard-v2-workbook")
  parent_id = azurerm_resource_group.claude.id
  location  = azurerm_resource_group.claude.location
  tags = merge(local.tags, {
    hidden-title = var.workbook_display_name
  })

  body = {
    kind = "shared"
    properties = {
      category       = "workbook"
      displayName    = var.workbook_display_name
      description    = "Claude user, subscription, token, cached input, cost, reliability, and APIM capacity governance."
      sourceId       = lower(azurerm_log_analytics_workspace.claude.id)
      serializedData = jsonencode(local.claude_governance_workbook_data)
    }
  }
}
