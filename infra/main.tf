resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.name_suffix}"
  location = var.location
  tags     = local.tags
}

# 두 resource-specific 로그 테이블이 이 workspace에 저장된다. 사용자별 비용을 얼마나 오래
# 추적할 수 있는지는 workspace 보존 기간으로 결정되며 diagnostic setting에는 별도 보존 설정이 없다.
resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

# VNet을 사용하지 않는 classic tier 구성이다. classic APIM도 internet-facing backend에 고정된
# public egress IP를 사용하므로 Foundry firewall을 해당 IP로 제한할 수 있다. 이 구성에는 VNet,
# private endpoint, private DNS, jumpbox가 필요하지 않다.
resource "azurerm_api_management" "apim" {
  name                = local.apim_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_account" "foundry" {
  for_each = local.managed_foundry_accounts

  name                  = local.foundry_name
  resource_group_name   = azurerm_resource_group.rg.name
  location              = var.location
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = local.foundry_name
  tags                  = local.tags

  # Entra ID 인증만 허용한다. local auth를 끄면 유출 가능한 account key가 없으므로 IP 규칙이
  # 완화되더라도 Gateway의 managed identity만 모델을 호출할 수 있다.
  local_auth_enabled = false

  # public 경로에서만 IP firewall 규칙을 적용할 수 있으므로 의도적으로 활성화한다.
  # default action이 Deny가 아니면 아래 허용 IP 규칙은 접근 제한 역할을 하지 못한다.
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    ip_rules       = azurerm_api_management.apim.public_ip_addresses
  }

  identity {
    type = "SystemAssigned"
  }
}

moved {
  from = azurerm_cognitive_account.foundry
  to   = azurerm_cognitive_account.foundry["gateway"]
}

data "azapi_resource" "external_foundry_project" {
  for_each = local.external_foundry_project_ids

  type                   = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  resource_id            = each.value
  response_export_values = ["properties.endpoints"]
}

resource "azurerm_cognitive_deployment" "models" {
  for_each             = var.model_deployments
  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.foundry["gateway"].id

  model {
    format  = each.value.model_format
    name    = each.value.model_name
    version = each.value.model_version
  }

  version_upgrade_option = each.value.version_upgrade_option

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }
}

# Gateway는 Azure OpenAI 호환 추론 작업만 제공하므로 범위가 넓은 Cognitive Services User 대신
# 모델 추론에 필요한 Cognitive Services OpenAI User 역할만 부여한다.
resource "azurerm_role_assignment" "apim_to_foundry" {
  for_each = local.managed_foundry_account_enabled ? toset([
    "Cognitive Services OpenAI User"
  ]) : toset([])

  scope                = azurerm_cognitive_account.foundry["gateway"].id
  role_definition_name = each.key
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_role_assignment" "apim_to_external_foundry_project" {
  for_each = local.external_foundry_project_ids

  scope                = each.value
  role_definition_name = "Foundry User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

# 이 설정을 생성하면 APIM이 verbosity=information 및 largeLanguageModel.logs=enabled인
# `azuremonitor` diagnostic entity를 구성한다. 이 설정이 LLM 로그 행을 생성하고 trace policy를
# Azure Monitor로 전달한다. Dedicated는 공용 AzureDiagnostics 대신 resource-specific 테이블
# (ApiManagementGatewayLogs / ApiManagementGatewayLlmLog)을 사용한다는 의미다.
resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                           = "resource-logs"
  target_resource_id             = azurerm_api_management.apim.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.law.id
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

  # GatewayLlmLogs를 활성화하면 APIM이 이 logger를 참조하는 service-level
  # azuremonitor diagnostic을 구성한다. 명시적 의존성으로 destroy 시 diagnostic
  # setting이 logger보다 먼저 제거되게 한다.
  depends_on = [azapi_resource.azure_monitor_logger]
}

# 모델마다 APIM backend를 하나씩 생성하여 circuit breaker 상태를 모델별로 분리한다.
# Terraform이 관리하는 모델은 이 stack의 Azure OpenAI endpoint를 사용하고, 외부 프로젝트 모델은
# 기존 Foundry project endpoint를 사용하면서 모델 배포 수명주기는 원본 프로젝트가 계속 관리한다.
resource "azurerm_api_management_backend" "model" {
  for_each            = local.model_targets
  name                = local.model_backend_ids[each.key]
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  protocol            = "http"
  url                 = each.value.backend_url

  # coding agent의 반복 재시도로 backend 429가 급증하면 thundering herd가 발생할 수 있다.
  # 각 클라이언트가 계속 재시도하게 두는 대신 circuit을 잠시 열어 backend가 회복할 시간을 준다.
  # Azure OpenAI backend의 Retry-After 값을 수용하여 실제 quota window만큼 기다린다. 이 값보다
  # 짧게 임의 설정하면 circuit이 닫힌 직후 다시 열릴 수 있다.
  # APIM backend마다 circuit breaker rule은 하나만 구성할 수 있으므로 현재는 429만 처리한다.
  # 향후 5xx를 별도로 처리하려면 두 번째 backend entity가 필요하다.
  circuit_breaker_rule {
    name                       = "backend-429"
    trip_duration              = "PT10S"
    accept_retry_after_enabled = true

    failure_condition {
      count             = 50
      interval_duration = "PT1M"

      status_code_range {
        min = 429
        max = 429
      }
    }
  }
}

resource "azurerm_api_management_api" "gateway" {
  name                = "model-gateway"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "Model Gateway"
  path                = "openai/v1"
  protocols           = ["https"]

  # 이 API에는 subscription key를 발급하지 않는다. 따라서 유효한 OIDC access token이 없는 요청은
  # 다른 인증 경로로 우회할 수 없다.
  subscription_required = false
}

resource "azurerm_api_management_api" "service_gateway" {
  name                = "service-model-gateway"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "Service Model Gateway"
  path                = "service/openai/v1"
  protocols           = ["https"]

  # APIM이 policy 실행 전에 API 범위 subscription key를 검증한다. 사용자 OIDC JWT는 요구하지 않는다.
  subscription_required = true
}

resource "azapi_resource" "azure_monitor_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2025-09-01-preview"
  name      = "azuremonitor"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      loggerType  = "azureMonitor"
      description = "Azure Monitor logger for gateway and LLM diagnostics."
      isBuffered  = false
    }
  }
}

# AzureRM provider가 아직 preview largeLanguageModel diagnostic 설정을 제공하지 않아 AzAPI를
# 사용한다. API 범위의 Azure Monitor diagnostic으로 prompt와 응답 본문은 기록하지 않으면서
# token 로그 행과 trace record를 활성화한다.
resource "azapi_resource" "gateway_diagnostic" {
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2025-09-01-preview"
  name      = "azuremonitor"
  parent_id = azurerm_api_management_api.gateway.id

  body = {
    properties = {
      loggerId    = azapi_resource.azure_monitor_logger.id
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

resource "azapi_resource" "service_gateway_diagnostic" {
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2025-09-01-preview"
  name      = "azuremonitor"
  parent_id = azurerm_api_management_api.service_gateway.id

  body = {
    properties = {
      loggerId    = azapi_resource.azure_monitor_logger.id
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

resource "azurerm_api_management_api_operation" "chat_completions" {
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.gateway.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Chat Completions"
  method              = "POST"
  url_template        = "/chat/completions"
}

resource "azurerm_api_management_api_operation" "responses" {
  operation_id        = "responses"
  api_name            = azurerm_api_management_api.gateway.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Responses"
  method              = "POST"
  url_template        = "/responses"
}

resource "azurerm_api_management_api_operation" "service_chat_completions" {
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.service_gateway.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Chat Completions"
  method              = "POST"
  url_template        = "/chat/completions"
}

resource "azurerm_api_management_api_operation" "service_responses" {
  operation_id        = "responses"
  api_name            = azurerm_api_management_api.service_gateway.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Responses"
  method              = "POST"
  url_template        = "/responses"
}

resource "azurerm_api_management_api_policy" "gateway" {
  api_name            = azurerm_api_management_api.gateway.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = templatefile(
    "${path.module}/../policies/gateway.xml.tftpl",
    merge(local.gateway_policy_parameters, { authentication_mode = "oidc" })
  )

  lifecycle {
    precondition {
      condition     = length(local.undeployed_routed) == 0
      error_message = "routed_models contains models with no deployment: ${join(", ", local.undeployed_routed)}."
    }
  }

  # policy는 backend 이름을 직접 참조하고 managed identity로 요청을 전달하므로 모든 backend가
  # 먼저 존재해야 한다. 모델을 제거할 때는 backend를 유지한 채 route를 먼저 제거해 적용하고,
  # 두 번째 적용에서 deployment 항목을 제거해야 한다.
  depends_on = [
    azurerm_api_management_backend.model,
    azurerm_role_assignment.apim_to_foundry,
    azurerm_role_assignment.apim_to_external_foundry_project,
    azurerm_api_management_api_operation.chat_completions,
    azurerm_api_management_api_operation.responses,
  ]
}

resource "azurerm_api_management_api_policy" "service_gateway" {
  api_name            = azurerm_api_management_api.service_gateway.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = templatefile(
    "${path.module}/../policies/gateway.xml.tftpl",
    merge(local.gateway_policy_parameters, { authentication_mode = "subscription" })
  )

  depends_on = [
    azurerm_api_management_backend.model,
    azurerm_role_assignment.apim_to_foundry,
    azurerm_role_assignment.apim_to_external_foundry_project,
    azurerm_api_management_api_operation.service_chat_completions,
    azurerm_api_management_api_operation.service_responses,
  ]
}
