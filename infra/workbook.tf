data "azurerm_client_config" "current" {}

resource "random_uuid" "governance_workbook" {}

locals {
  governance_price_rows = join(",\n", [
    for model_name in local.routed_models :
    "  ${jsonencode(model_name)}, ${jsonencode(try(var.model_pricing_usd_per_million[model_name].input, 0))}, ${jsonencode(try(var.model_pricing_usd_per_million[model_name].output, 0))}"
  ])

  governance_capacity_rows = join(",\n", [
    for model_name in local.routed_models :
    "  ${jsonencode(model_name)}, ${jsonencode(local.model_capacity_tpm[model_name])}"
  ])

  governance_pricing_summary = join(" · ", [
    for model_name in local.routed_models :
    "${model_name}: input ${try(var.model_pricing_usd_per_million[model_name].input, 0)} / output ${try(var.model_pricing_usd_per_million[model_name].output, 0)} USD per 1M"
  ])

  governance_base_query = <<-KQL
    let ModelPrices = datatable(Model:string, InputUsdPerMillion:real, OutputUsdPerMillion:real) [
    ${local.governance_price_rows}
    ];
    let ModelLimits = datatable(Model:string, TpmLimit:long) [
    ${local.governance_capacity_rows}
    ];
    let GatewayAll = materialize(
        ApiManagementGatewayLogs
        | summarize arg_max(TimeGenerated, *) by CorrelationId
        | extend TraceArray = todynamic(TraceRecords)
        | extend GovernanceTrace = iff(coalesce(array_length(TraceArray), 0) > 0, TraceArray[0], dynamic(null))
        | extend
            UserId = tostring(GovernanceTrace.metadata.userId),
            UserLabel = tostring(GovernanceTrace.metadata.userLabel)
        | extend UserId = iff(isempty(UserId), "anonymous", UserId)
        | extend UserLabel = iff(
            isempty(UserLabel),
            iff(UserId == "anonymous", "anonymous", substring(UserId, 0, 12)),
            UserLabel
          )
        | extend RequestedModel = tostring(GovernanceTrace.metadata.requestedModel)
        | project
            RequestTime = TimeGenerated,
            CorrelationId,
            UserId,
            UserLabel,
            RequestedModel,
            ResponseCode = toint(ResponseCode),
            BackendResponseCode = toint(BackendResponseCode),
            TotalTimeMs = todouble(TotalTime),
            BackendTimeMs = todouble(BackendTime),
            ApiId = tostring(ApiId),
            OperationId = tostring(OperationId),
            LastErrorReason = tostring(LastErrorReason)
    );
    let Gateway = materialize(
        GatewayAll
        | where ApiId in ("model-gateway", "service-model-gateway")
        | where OperationId in ("chat-completions", "responses")
    );
    let Tokens = materialize(
        ApiManagementGatewayLlmLog
        | summarize arg_max(TimeGenerated, *) by CorrelationId
        | project
            CorrelationId,
            TokenLogTime = TimeGenerated,
            PromptTokens = tolong(PromptTokens),
            CompletionTokens = tolong(CompletionTokens),
            TotalTokens = tolong(TotalTokens),
            ModelName = tostring(ModelName),
            DeploymentName = tostring(DeploymentName)
    );
    let RequestData = materialize(
        Gateway
        | join kind=leftouter Tokens on CorrelationId
        | extend Model = coalesce(DeploymentName, ModelName, RequestedModel, "unknown")
        | join kind=leftouter ModelPrices on Model
        | extend
            PromptTokens = coalesce(PromptTokens, tolong(0)),
            CompletionTokens = coalesce(CompletionTokens, tolong(0)),
            TotalTokens = coalesce(TotalTokens, tolong(0)),
            InputUsdPerMillion = coalesce(InputUsdPerMillion, 0.0),
            OutputUsdPerMillion = coalesce(OutputUsdPerMillion, 0.0)
        | extend
            IsSuccess = ResponseCode between (200 .. 299),
            IsPriceConfigured = InputUsdPerMillion > 0.0 or OutputUsdPerMillion > 0.0,
            EstimatedCostUsd =
                todouble(PromptTokens) * InputUsdPerMillion / 1000000.0
                + todouble(CompletionTokens) * OutputUsdPerMillion / 1000000.0
    );
  KQL

  governance_query_common = {
    version                  = "KqlItem/1.0"
    size                     = 1
    timeContext              = { durationMs = 0 }
    timeContextFromParameter = "TimeRange"
    queryType                = 0
    resourceType             = "microsoft.operationalinsights/workspaces"
    crossComponentResources  = [azurerm_log_analytics_workspace.law.id]
    showAnalytics            = true
    showExportToExcel        = true
  }

  governance_grid_settings = {
    filter = true
  }

  governance_tile_settings = {
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

  governance_workbook_data = {
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "introduction"
        content = {
          json = <<-MARKDOWN
            # LLM Gateway Governance

            사용자·모델별 사용량, 토큰, 비용 추정, 오류, 지연, 모델 TPM headroom과 APIM 용량을 한 화면에서 확인합니다.
            사용자 식별자는 `tid:oid` 또는 `iss:sub`의 SHA-256 해시이며 이름·메일·원본 object ID는 저장하지 않습니다.

            **모델 한도:** ${join(" · ", [for model_name in local.routed_models : "${model_name} ${local.model_capacity_tpm[model_name]} TPM"])}

            **비용 입력:** ${local.governance_pricing_summary}. 단가가 0이면 비용은 의도적으로 0으로 표시합니다.
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
              id         = "8d4b4928-b118-4c08-a38b-3cdfa2926330"
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
                  { durationMs = 2592000000 },
                  { durationMs = 5184000000 },
                  { durationMs = 7776000000 }
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
          json = "## Overview\n선택 기간의 사용자 수, 요청, 토큰, 비용, 성공률과 지연을 요약합니다."
        }
      },
      {
        type = 3
        name = "overview-kpis"
        content = merge(local.governance_query_common, {
          title         = "Key indicators"
          visualization = "tiles"
          tileSettings  = local.governance_tile_settings
          query         = <<-KQL
            ${local.governance_base_query}
            union
                (RequestData
                 | summarize Value = todouble(dcountif(UserId, UserId != "anonymous"))
                 | extend SortOrder = 1, Metric = "Active users"),
                (RequestData
                 | summarize Value = todouble(count())
                 | extend SortOrder = 2, Metric = "Requests"),
                (RequestData
                 | summarize Value = todouble(sum(PromptTokens))
                 | extend SortOrder = 3, Metric = "Prompt tokens"),
                (RequestData
                 | summarize Value = todouble(sum(CompletionTokens))
                 | extend SortOrder = 4, Metric = "Completion tokens"),
                (RequestData
                 | summarize Value = todouble(sum(TotalTokens))
                 | extend SortOrder = 5, Metric = "Total tokens"),
                (RequestData
                 | summarize Value = round(sum(EstimatedCostUsd), 4)
                 | extend SortOrder = 6, Metric = "Estimated cost (USD)"),
                (RequestData
                 | summarize Requests = count(), Successful = countif(IsSuccess)
                 | extend Value = iff(Requests == 0, 0.0, round(100.0 * todouble(Successful) / todouble(Requests), 2))
                 | extend SortOrder = 7, Metric = "Success rate (%)"),
                (RequestData
                 | summarize Value = round(percentile(TotalTimeMs, 95), 0)
                 | extend SortOrder = 8, Metric = "End-to-end p95 (ms)")
            | project SortOrder, Metric, Value
            | order by SortOrder asc
          KQL
        })
      },
      {
        type        = 3
        name        = "traffic-health"
        customWidth = "50"
        content = merge(local.governance_query_common, {
          title         = "Traffic and failures"
          visualization = "timechart"
          query         = <<-KQL
            ${local.governance_base_query}
            let Grain = {TimeRange:grain};
            RequestData
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
        content = merge(local.governance_query_common, {
          title         = "Prompt and completion tokens by model"
          visualization = "timechart"
          query         = <<-KQL
            ${local.governance_base_query}
            let Grain = {TimeRange:grain};
            let TokenSeries =
                RequestData
                | where Model != "unknown"
                | summarize
                    PromptTokens = sum(PromptTokens),
                    CompletionTokens = sum(CompletionTokens)
                    by TimeGenerated = bin(RequestTime, Grain), Model;
            union
                (TokenSeries | project TimeGenerated, Series = strcat(Model, " prompt"), Value = PromptTokens),
                (TokenSeries | project TimeGenerated, Series = strcat(Model, " completion"), Value = CompletionTokens)
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type = 3
        name = "model-usage-cost"
        content = merge(local.governance_query_common, {
          title        = "Model usage and estimated cost"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            RequestData
            | where Model != "unknown"
            | summarize
                Requests = count(),
                ActiveUsers = dcountif(UserId, UserId != "anonymous"),
                PromptTokens = sum(PromptTokens),
                CompletionTokens = sum(CompletionTokens),
                TotalTokens = sum(TotalTokens),
                EstimatedCostUsd = round(sum(EstimatedCostUsd), 4),
                Successful = countif(IsSuccess),
                P95LatencyMs = round(percentile(TotalTimeMs, 95), 0),
                PriceConfiguredRows = countif(IsPriceConfigured)
                by Model
            | extend
                SuccessRatePct = round(100.0 * todouble(Successful) / todouble(Requests), 2),
                Pricing = iff(PriceConfiguredRows > 0, "configured", "zero/unset")
            | project Model, Requests, ActiveUsers, PromptTokens, CompletionTokens, TotalTokens,
                EstimatedCostUsd, Pricing, SuccessRatePct, P95LatencyMs
            | order by TotalTokens desc
          KQL
        })
      },
      {
        type = 1
        name = "users-heading"
        content = {
          json = "## Users\nOIDC user label별 점유율, burst, 오류와 모델 사용을 확인합니다. 집계 키는 가명 처리된 사용자 ID를 유지합니다."
        }
      },
      {
        type        = 3
        name        = "active-users"
        customWidth = "50"
        content = merge(local.governance_query_common, {
          title         = "Active users over time"
          visualization = "timechart"
          chartSettings = {
            showMetrics = false
            showLegend  = true
            simpleLegendSettings = {
              position = "bottom"
            }
            ySettings = {
              label = "Active users"
            }
          }
          query = <<-KQL
            ${local.governance_base_query}
            let Grain = {TimeRange:grain};
            RequestData
            | where UserId != "anonymous"
            | summarize ActiveUsers = dcount(UserId) by TimeGenerated = bin(RequestTime, Grain)
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type        = 3
        name        = "top-users"
        customWidth = "50"
        content = merge(local.governance_query_common, {
          title         = "Top 10 users by tokens"
          visualization = "barchart"
          query         = <<-KQL
            ${local.governance_base_query}
            RequestData
            | where UserId != "anonymous"
            | summarize TotalTokens = sum(TotalTokens), arg_max(RequestTime, UserLabel) by UserId
            | project User = UserLabel, TotalTokens
            | top 10 by TotalTokens desc
          KQL
        })
      },
      {
        type = 3
        name = "usage-concentration"
        content = merge(local.governance_query_common, {
          title         = "Usage concentration"
          visualization = "tiles"
          tileSettings  = local.governance_tile_settings
          query         = <<-KQL
            ${local.governance_base_query}
            let Users =
                RequestData
                | where UserId != "anonymous"
                | summarize Tokens = sum(TotalTokens) by UserId
                | order by Tokens desc
                | serialize Rank = row_number();
            let AllTokens = toscalar(Users | summarize sum(Tokens));
            union
                (Users | summarize SliceTokens = sumif(Tokens, Rank <= 1)
                 | extend SortOrder = 1, Metric = "Top 1 user share (%)"),
                (Users | summarize SliceTokens = sumif(Tokens, Rank <= 5)
                 | extend SortOrder = 2, Metric = "Top 5 user share (%)"),
                (Users | summarize SliceTokens = sumif(Tokens, Rank <= 10)
                 | extend SortOrder = 3, Metric = "Top 10 user share (%)")
            | extend Value = iff(AllTokens == 0, 0.0, round(100.0 * todouble(SliceTokens) / todouble(AllTokens), 2))
            | project SortOrder, Metric, Value
            | order by SortOrder asc
          KQL
        })
      },
      {
        type = 3
        name = "user-detail"
        content = merge(local.governance_query_common, {
          title        = "User detail"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            let AllTokens = toscalar(
                RequestData
                | where UserId != "anonymous"
                | summarize sum(TotalTokens)
            );
            let PerMinute =
                RequestData
                | where UserId != "anonymous"
                | summarize RPM = count(), TPM = sum(TotalTokens) by UserId, bin(RequestTime, 1m);
            let Peaks =
                PerMinute
                | summarize PeakRPM = max(RPM), PeakTPM = max(TPM) by UserId;
            RequestData
            | where UserId != "anonymous"
            | summarize
                arg_max(RequestTime, UserLabel),
                Requests = count(),
                PromptTokens = sum(PromptTokens),
                CompletionTokens = sum(CompletionTokens),
                TotalTokens = sum(TotalTokens),
                EstimatedCostUsd = round(sum(EstimatedCostUsd), 4),
                Successful = countif(IsSuccess),
                RateLimited429 = countif(ResponseCode == 429),
                Forbidden403 = countif(ResponseCode == 403),
                ServerErrors = countif(ResponseCode >= 500),
                P95LatencyMs = round(percentile(TotalTimeMs, 95), 0),
                Models = strcat_array(make_set(Model, 10), ", "),
                LastSeen = max(RequestTime)
                by UserId
            | join kind=leftouter Peaks on UserId
            | extend
                User = UserLabel,
                UserHash = UserId,
                TokenSharePct = iff(AllTokens == 0, 0.0, round(100.0 * todouble(TotalTokens) / todouble(AllTokens), 2)),
                SuccessRatePct = round(100.0 * todouble(Successful) / todouble(Requests), 2),
                AverageTokensPerRequest = round(todouble(TotalTokens) / todouble(Requests), 0),
                UserLimitUtilizationPct = iff(
                    ${var.user_tokens_per_minute} > 0,
                    round(100.0 * todouble(PeakTPM) / todouble(${max(var.user_tokens_per_minute, 1)}), 2),
                    real(null)
                )
            | project User, UserHash, Requests, PromptTokens, CompletionTokens, TotalTokens, TokenSharePct,
                EstimatedCostUsd, AverageTokensPerRequest, PeakRPM, PeakTPM, UserLimitUtilizationPct,
                SuccessRatePct, P95LatencyMs, RateLimited429, Forbidden403, ServerErrors, Models, LastSeen
            | order by TotalTokens desc
          KQL
        })
      },
      {
        type = 3
        name = "user-burst"
        content = merge(local.governance_query_common, {
          title        = "Top user bursts"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            RequestData
            | where UserId != "anonymous"
            | summarize RPM = count(), TPM = sum(TotalTokens), arg_max(RequestTime, UserLabel)
                by UserId, Minute = bin(RequestTime, 1m)
            | summarize
                arg_max(RequestTime, UserLabel),
                PeakRPM = max(RPM),
                PeakTPM = max(TPM),
                AverageActiveMinuteTPM = round(avg(todouble(TPM)), 0)
                by UserId
            | extend
                User = UserLabel,
                UserHash = UserId,
                BurstRatio = iff(AverageActiveMinuteTPM == 0, 0.0, round(todouble(PeakTPM) / AverageActiveMinuteTPM, 2)),
                UserLimitUtilizationPct = iff(
                    ${var.user_tokens_per_minute} > 0,
                    round(100.0 * todouble(PeakTPM) / todouble(${max(var.user_tokens_per_minute, 1)}), 2),
                    real(null)
                )
            | project User, UserHash, PeakRPM, PeakTPM, AverageActiveMinuteTPM, BurstRatio, UserLimitUtilizationPct
            | top 20 by PeakTPM desc
          KQL
        })
      },
      {
        type = 1
        name = "capacity-heading"
        content = {
          json = "## Capacity and latency\n모델별 분당 토큰과 배포 한도, APIM 용량, 오류율과 지연을 함께 확인합니다. 장기 범위의 TPM 차트는 화면 grain으로 분당 평균화하며 peak 표는 실제 1분 bucket을 사용합니다. APIM 차트는 플랫폼 Metrics를 직접 조회합니다. Gateway CPU/Memory는 v2 SKU에서만 제공되므로 현재 classic SKU에서는 Capacity만 표시됩니다."
        }
      },
      {
        type = 3
        name = "model-tpm"
        content = merge(local.governance_query_common, {
          title         = "Model TPM versus deployed limit"
          visualization = "timechart"
          query         = <<-KQL
            ${local.governance_base_query}
            let Grain = {TimeRange:grain};
            let Usage =
                RequestData
                | where Model != "unknown"
                | summarize Tokens = sum(TotalTokens) by TimeGenerated = bin(RequestTime, Grain), Model
                | join kind=inner ModelLimits on Model
                | extend TokensPerMinute = round(todouble(Tokens) / max_of(1.0, todouble(Grain / 1m)), 0);
            union
                (Usage | project TimeGenerated, Series = strcat(Model, " actual"), Value = TokensPerMinute),
                (Usage | project TimeGenerated, Series = strcat(Model, " limit"), Value = todouble(TpmLimit))
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type = 3
        name = "model-headroom"
        content = merge(local.governance_query_common, {
          title        = "Model peak and headroom"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            let MinuteUsage =
                RequestData
                | where Model != "unknown"
                | summarize TPM = sum(TotalTokens), RPM = count() by Model, bin(RequestTime, 1m);
            let Peaks =
                MinuteUsage
                | summarize PeakTPM = max(TPM), PeakRPM = max(RPM) by Model;
            let Errors =
                RequestData
                | where Model != "unknown"
                | summarize RateLimited429 = countif(ResponseCode == 429), ServiceUnavailable503 = countif(ResponseCode == 503) by Model;
            ModelLimits
            | join kind=leftouter Peaks on Model
            | join kind=leftouter Errors on Model
            | extend
                PeakTPM = coalesce(PeakTPM, tolong(0)),
                PeakRPM = coalesce(PeakRPM, tolong(0)),
                RateLimited429 = coalesce(RateLimited429, tolong(0)),
                ServiceUnavailable503 = coalesce(ServiceUnavailable503, tolong(0))
            | extend
                PeakUtilizationPct = round(100.0 * todouble(PeakTPM) / todouble(TpmLimit), 2),
                HeadroomAtPeak = max_of(TpmLimit - PeakTPM, tolong(0))
            | project Model, TpmLimit, PeakTPM, PeakUtilizationPct, HeadroomAtPeak, PeakRPM,
                RateLimited429, ServiceUnavailable503
            | order by PeakUtilizationPct desc
          KQL
        })
      },
      {
        type        = 3
        name        = "request-rate"
        customWidth = "50"
        content = merge(local.governance_query_common, {
          title         = "Request rate and capacity errors"
          visualization = "timechart"
          query         = <<-KQL
            ${local.governance_base_query}
            let Grain = {TimeRange:grain};
            RequestData
            | summarize
                Requests = count(),
                RateLimited429 = countif(ResponseCode == 429),
                ServiceUnavailable503 = countif(ResponseCode == 503)
                by TimeGenerated = bin(RequestTime, Grain)
            | extend RPM = round(todouble(Requests) / max_of(1.0, todouble(Grain / 1m)), 2)
            | project TimeGenerated, RPM, RateLimited429, ServiceUnavailable503
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type        = 3
        name        = "latency"
        customWidth = "50"
        content = merge(local.governance_query_common, {
          title         = "Latency percentiles"
          visualization = "timechart"
          query         = <<-KQL
            ${local.governance_base_query}
            let Grain = {TimeRange:grain};
            RequestData
            | summarize
                EndToEndP50Ms = percentile(TotalTimeMs, 50),
                EndToEndP95Ms = percentile(TotalTimeMs, 95),
                EndToEndP99Ms = percentile(TotalTimeMs, 99),
                BackendP95Ms = percentile(BackendTimeMs, 95)
                by TimeGenerated = bin(RequestTime, Grain)
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type = 10
        name = "apim-resource-metrics"
        content = {
          chartId                  = "workbook6c8e8342-dfb1-4c71-b157-ec0450bc3e88"
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.apimanagement/service"
          metricScope              = 0
          resourceIds              = [azurerm_api_management.apim.id]
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
        type = 10
        name = "apim-resource-peaks"
        content = {
          chartId                  = "workbook9e1474ad-f894-47aa-8e12-5c9ddc36e8c1"
          version                  = "MetricsItem/2.0"
          size                     = 1
          chartType                = -1
          resourceType             = "microsoft.apimanagement/service"
          metricScope              = 0
          resourceIds              = [azurerm_api_management.apim.id]
          timeContext              = { durationMs = 0 }
          timeContextFromParameter = "TimeRange"
          metrics = [
            {
              namespace   = "microsoft.apimanagement/service"
              metric      = "microsoft.apimanagement/service-Capacity-Capacity"
              aggregation = 3
              splitBy     = null
              columnName  = "Peak APIM capacity (%)"
            },
            {
              namespace   = "microsoft.apimanagement/service"
              metric      = "microsoft.apimanagement/service-Capacity-CpuPercent_Gateway"
              aggregation = 3
              splitBy     = null
              columnName  = "Peak gateway CPU (%)"
            },
            {
              namespace   = "microsoft.apimanagement/service"
              metric      = "microsoft.apimanagement/service-Capacity-MemoryPercent_Gateway"
              aggregation = 3
              splitBy     = null
              columnName  = "Peak gateway memory (%)"
            }
          ]
          title          = "APIM metric peaks"
          resourceLimit  = 10
          gridFormatType = 1
          tileSettings   = local.governance_tile_settings
          filters        = []
        }
      },
      {
        type = 1
        name = "governance-heading"
        content = {
          json = "## Governance and errors\n인증·미지원 모델·사용자 제한·백엔드 상태 문제를 분리해 운영 조치 대상을 찾습니다. 401은 JWT 검증 전에 종료되므로 anonymous가 정상입니다. API/operation 매칭 전에 종료된 public probe 404는 운영 지표에서 제외됩니다."
        }
      },
      {
        type = 3
        name = "policy-errors"
        content = merge(local.governance_query_common, {
          title         = "Authentication, policy, and service errors"
          visualization = "timechart"
          query         = <<-KQL
            ${local.governance_base_query}
            let Grain = {TimeRange:grain};
            RequestData
            | summarize
                Unauthorized401 = countif(ResponseCode == 401),
                Forbidden403 = countif(ResponseCode == 403),
                BadRequest400 = countif(ResponseCode == 400),
                RateLimited429 = countif(ResponseCode == 429),
                ServerErrors5xx = countif(ResponseCode >= 500)
                by TimeGenerated = bin(RequestTime, Grain)
            | order by TimeGenerated asc
          KQL
        })
      },
      {
        type        = 3
        name        = "blocked-models"
        customWidth = "50"
        content = merge(local.governance_query_common, {
          title        = "Blocked model attempts"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            RequestData
            | where ResponseCode == 403
            | summarize Attempts = count(), Users = dcountif(UserId, UserId != "anonymous"), LastSeen = max(RequestTime)
                by RequestedModel
            | extend RequestedModel = iff(isempty(RequestedModel), "(missing)", RequestedModel)
            | order by Attempts desc
          KQL
        })
      },
      {
        type        = 3
        name        = "throttling-errors"
        customWidth = "50"
        content = merge(local.governance_query_common, {
          title        = "Rate limits and backend availability"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            RequestData
            | where ResponseCode in (429, 503)
            | extend Reason = iff(isempty(LastErrorReason), "policy/backend response", LastErrorReason)
            | summarize
                Attempts = count(),
                AffectedUsers = dcountif(UserId, UserId != "anonymous"),
                Reasons = strcat_array(make_set(Reason, 10), ", "),
                LastSeen = max(RequestTime)
                by ResponseCode, Model
            | order by Attempts desc
          KQL
        })
      },
      {
        type = 3
        name = "operation-breakdown"
        content = merge(local.governance_query_common, {
          title        = "Endpoint and model breakdown"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            RequestData
            | summarize
                Requests = count(),
                ActiveUsers = dcountif(UserId, UserId != "anonymous"),
                TotalTokens = sum(TotalTokens),
                Successful = countif(IsSuccess),
                P95LatencyMs = round(percentile(TotalTimeMs, 95), 0)
                by OperationId, Model
            | extend SuccessRatePct = round(100.0 * todouble(Successful) / todouble(Requests), 2)
            | project OperationId, Model, Requests, ActiveUsers, TotalTokens, SuccessRatePct, P95LatencyMs
            | order by Requests desc
          KQL
        })
      },
      {
        type = 3
        name = "error-reasons"
        content = merge(local.governance_query_common, {
          title        = "Top error reasons"
          gridSettings = local.governance_grid_settings
          query        = <<-KQL
            ${local.governance_base_query}
            RequestData
            | where ResponseCode >= 400
            | extend Reason = iff(isempty(LastErrorReason), "policy/client response", LastErrorReason)
            | summarize Errors = count(), AffectedUsers = dcountif(UserId, UserId != "anonymous"), LastSeen = max(RequestTime)
                by ResponseCode, BackendResponseCode, Reason, Model
            | top 30 by Errors desc
          KQL
        })
      },
      {
        type = 1
        name = "notes"
        content = {
          json = <<-MARKDOWN
            ---
            **해석 주의**

            * 스트리밍 요청이 중간 취소되면 usage 청크가 없어 zero-token으로 남을 수 있습니다.
            * `Estimated cost`는 Terraform의 `model_pricing_usd_per_million` 값만 사용하며 Azure 청구서가 아닙니다.
            * APIM Capacity 차트는 플랫폼 Metrics를 직접 조회합니다.
            * Gateway CPU/Memory metric은 APIM v2 SKU 전용입니다. 현재 classic SKU에서는 Capacity가 해당 상태 지표입니다.
            * 401은 사용자 claim을 읽기 전에 차단되므로 사용자 귀속 대상이 아닙니다.
            * API/operation 매칭 전 `OperationNotFound` 404는 public endpoint probe로 분리하며 이 운영 대시보드에는 포함하지 않습니다.
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

resource "azurerm_application_insights_workbook" "governance" {
  name                = random_uuid.governance_workbook.result
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  display_name        = var.governance_workbook_display_name
  description         = "User, model, capacity, error, and latency governance for the LLM gateway."
  category            = "workbook"
  source_id           = lower(azurerm_log_analytics_workspace.law.id)
  data_json           = jsonencode(local.governance_workbook_data)
  tags                = local.tags

  depends_on = [azurerm_monitor_diagnostic_setting.apim]
}
