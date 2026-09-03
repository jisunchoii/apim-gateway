# Korea Central Claude Standard v2 APIM 구축 가이드


이 문서는 Terraform 배포와 운영 검증을 다룹니다. Databricks identity, model 권한과 network
설정은 [Databricks Claude 고객 설정 가이드](databricks-claude-apim-guide.md), 최종 사용자
Claude Code 설정은 [README](../README.md#claude-code)를 사용합니다.

## 구성

```text
Claude Code
  -> Korea Central Standard v2 APIM
       -> 기존 Keycloak JWT 검증
       -> system.ai Claude family 검사
       -> APIM Managed Identity로 Databricks 인증
       -> Azure Databricks /ai-gateway/anthropic/v1/messages
       -> Anthropic SSE passthrough

APIM outbound
  -> delegated subnet
  -> StandardV2 NAT Gateway
  -> static public IP
```

Terraform root는 `infra/environments/claude-standard-v2/`이며 기존 `infra/`와 분리된 state를
사용합니다. 운영 환경은 Azure Blob backend를 기본으로 사용하고, Storage data plane에 접근할
수 없는 제한된 검증 환경에서는 별도로 백업하는 local state를 사용할 수 있습니다. 이 root에는
Azure AI Services account, 모델 deployment, backend pool이 없습니다.

## 배포 전 Databricks 전제

이 Terraform root는 Databricks workspace를 생성하거나 ARM으로 조회하지 않고 `workspace_url`만
backend 주소로 사용합니다. 배포 전에 고객 관리자가 같은 Microsoft Entra tenant, public
endpoint/NAT 연결, 대상 `system.ai` 모델 제공 여부와 Service Principal 등록 가능 여부를
[고객 설정 가이드의 사전 확인](databricks-claude-apim-guide.md#기존-workspace-재사용-전제-확인)에
따라 확인합니다.

## 1. 입력 파일

```bash
cp infra/environments/claude-standard-v2/terraform.tfvars.example \
  infra/environments/claude-standard-v2/terraform.tfvars
```

다음 항목을 고객 환경 값으로 변경합니다.

- owner와 cost center
- APIM publisher 이름과 메일
- 기존 Keycloak discovery URL, issuer, audience, scope, role, client ID
- 기존 Databricks workspace URL
- 현재 사용할 Opus, Sonnet, Haiku, Fable `system.ai` 모델명
- 고객 VNet과 겹치지 않는 VNet/subnet CIDR

실제 `terraform.tfvars`는 Git에 commit하지 않습니다.

## 2. Preflight

```bash
./scripts/preflight-claude-standard-v2.sh \
  --terraform-dir infra/environments/claude-standard-v2
```

preflight는 다음을 확인합니다.

- Korea Central `StandardV2` APIM 제공 여부와 최대 unit
- `Microsoft.ApiManagement`, `Microsoft.Network`, `Microsoft.Web`, `Microsoft.Insights`,
  `Microsoft.OperationalInsights` provider 등록
- Korea Central StandardV2 NAT Gateway와 StandardV2 public IP ARM validation
- Keycloak discovery URL의 DNS/TLS/HTTP 2xx 응답
- Databricks workspace URL의 DNS/TLS/HTTP 도달성
- Terraform init/validate


Databricks와 Keycloak HTTPS 검사는 preflight를 실행하는 PC/runner에서 수행됩니다. 이는 URL의
DNS/TLS/HTTP 응답만 확인하며, 배포 후 APIM subnet/NAT에서의 실제 경로, Databricks
subscription/tenant, IP access list, context-based ingress, Private Link/private DNS, Service
Principal 등록, model 권한 또는 Terraform backend Storage data-plane 접근은 확인하지
않습니다. 해당 항목은 배포 전후에 고객 Databricks/네트워크 관리자와 별도로 검증해야 합니다.

## 3. 독립 Terraform state

운영 환경에서는 다음 명령으로 Claude stack 전용 Azure Blob backend를 생성합니다.

```bash
./scripts/bootstrap-backend.sh \
  --terraform-dir infra/environments/claude-standard-v2

terraform -chdir=infra/environments/claude-standard-v2 init -reconfigure
```

기본 stack discriminator는 디렉터리 이름인 `claude-standard-v2`입니다. 기존 Classic state
storage account와 state key를 재사용하지 않습니다.

실행 PC 또는 runner가 backend Storage의 Blob data plane에 접근할 수 있어야 합니다. 조직의
Azure Policy가 Storage public network access를 `Disabled`로 강제한다면 Private Endpoint,
Network Security Perimeter 또는 고객이 승인한 private runner 경로를 먼저 구성해야 합니다.
`bootstrap-backend.sh`는 public access가 정책으로 다시 비활성화되면 원인을 표시하고 중단합니다.

원격 backend 연결이 준비되지 않은 제한된 검증 환경에서만 `backend.tf`가 없는 상태로 다음과
같이 local state를 사용할 수 있습니다.

```bash
terraform -chdir=infra/environments/claude-standard-v2 init -reconfigure
```

local state는
`infra/environments/claude-standard-v2/terraform.tfstate`에 저장됩니다. 동시에 여러 명이
배포하지 않고, 배포 전후에 Git 외부의 보호된 위치로 반드시 백업합니다.

## 4. Plan

```bash
terraform -chdir=infra/environments/claude-standard-v2 plan
```

plan에서 다음을 확인합니다.

- APIM `sku.name = StandardV2`
- APIM location `koreacentral`
- public inbound와 `virtualNetworkType = External`
- delegated subnet `Microsoft.Web/serverFarms`
- StandardV2 NAT Gateway와 StandardV2 static public IP
- Claude API, operation, Databricks backend, dedicated policy
- Log Analytics, workspace-based Application Insights, Workbook
- Azure Monitor `GatewayLogs`와 `GatewayLlmLogs`
- Application Insights diagnostic `metrics = true`
- `PremiumV2`, `zoneRedundant`, Azure AI Services account/deployment, backend pool 없음

기존 Classic root도 별도로 plan하여 APIM 또는 모델 resource의 replace/destroy가 없는지
확인합니다.

## 5. 배포

apply는 plan 승인 후 실행합니다.

```bash
./scripts/deploy.sh \
  --terraform-dir infra/environments/claude-standard-v2 \
  --registry-template docs/claude-standard-v2-registry.template.html \
  --registry-html docs/claude-standard-v2-registry.html
```

배포 후 주요 output:

```bash
terraform -chdir=infra/environments/claude-standard-v2 output -raw apim_name
terraform -chdir=infra/environments/claude-standard-v2 output -raw claude_gateway_base_url
terraform -chdir=infra/environments/claude-standard-v2 output -raw claude_service_gateway_base_url
terraform -chdir=infra/environments/claude-standard-v2 output -raw nat_gateway_public_ip
terraform -chdir=infra/environments/claude-standard-v2 output -raw apim_managed_identity_principal_id
terraform -chdir=infra/environments/claude-standard-v2 output -raw log_analytics_workspace_id
```

## 6. 배포 후 고객 작업

Terraform apply만으로 Databricks data-plane 권한은 생기지 않습니다. 배포 운영자는 고객
관리자에게 다음 값을 전달합니다.

| 전달 값 | Terraform output |
|---|---|
| APIM Managed Identity object ID | `apim_managed_identity_principal_id` |
| APIM outbound 고정 IP | `nat_gateway_public_ip` |
| 허용할 Claude 모델 | `claude_gateway_models` |

고객 관리자는 [Databricks Claude 고객 설정 가이드](databricks-claude-apim-guide.md)에 따라
Service Principal, workspace assignment, model `EXECUTE`와 network allowlist를 설정합니다.

## 7. 기능 검증

README의 Claude Code 설정과 동일한 OIDC discovery URL, client ID, scope를 사용합니다.
저장소와 local Terraform state가 있는 Linux 환경에서는 다음과 같이 사용자 API를 확인합니다.
Terraform state가 없는 사용자 PC에서는 `CLAUDE_GATEWAY_BASE_URL`을 운영자가 안내한 URL로
직접 설정합니다.

```bash
cd /home/<linux-user>/src/apim-gateway

export CLAUDE_GATEWAY_BASE_URL="$(
  terraform -chdir=infra/environments/claude-standard-v2 \
    output -raw claude_gateway_base_url
)"
export LLMGW_OIDC_DISCOVERY_URL="https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration"
export LLMGW_OIDC_CLIENT_ID="llm-gateway-cli"
export LLMGW_OIDC_SCOPE="openid llm-gateway"

token="$(node ./scripts/keycloak/keycloak-token.js --open-browser)"

curl --silent --show-error --fail-with-body \
  --request POST \
  --url "$CLAUDE_GATEWAY_BASE_URL/v1/messages" \
  --header "Authorization: Bearer $token" \
  --header "Content-Type: application/json" \
  --header "anthropic-version: 2023-06-01" \
  --data '{"model":"system.ai.claude-sonnet-5","max_tokens":32,"messages":[{"role":"user","content":"Reply only with CLAUDE_OK"}]}'
```

SSE streaming도 같은 token과 URL을 사용해 확인합니다.

```bash
curl --no-buffer --silent --show-error --fail-with-body \
  --request POST \
  --url "$CLAUDE_GATEWAY_BASE_URL/v1/messages" \
  --header "Authorization: Bearer $token" \
  --header "Content-Type: application/json" \
  --header "anthropic-version: 2023-06-01" \
  --data '{"model":"system.ai.claude-sonnet-5","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"Reply only with CLAUDE_STREAM_OK"}]}'
```

서비스 계정 API는 Keycloak token 대신 `Service Claude Gateway` API 범위로 발급한 APIM
subscription key를 사용합니다. 사용자별 subscription이나 전체 APIM 범위의 key를 재사용하지
않습니다.

```bash
export CLAUDE_SERVICE_GATEWAY_BASE_URL="$(
  terraform -chdir=infra/environments/claude-standard-v2 \
    output -raw claude_service_gateway_base_url
)"
export LLMGW_SUBSCRIPTION_KEY="<service-account-subscription-key>"

curl --silent --show-error --fail-with-body \
  --request POST \
  --url "$CLAUDE_SERVICE_GATEWAY_BASE_URL/v1/messages" \
  --header "Ocp-Apim-Subscription-Key: $LLMGW_SUBSCRIPTION_KEY" \
  --header "Content-Type: application/json" \
  --header "anthropic-version: 2023-06-01" \
  --data '{"model":"system.ai.claude-sonnet-5","max_tokens":32,"messages":[{"role":"user","content":"Reply only with CLAUDE_SERVICE_OK"}]}'
```

다음을 모두 확인합니다.

- token 없음/잘못된 token은 `401`
- `/service/anthropic/v1/messages`는 API-scoped APIM subscription key가 없으면 `401`
- 유효한 service API subscription key를 보내면 `/service/anthropic/v1/messages`가 `200`
- 허용되지 않은 model family는 `403`
- Opus, Sonnet, Haiku, Fable 요청은 각각 `200`
- streaming 요청은 `text/event-stream`과 Anthropic event를 중단 없이 반환
- `/v1/messages/count_tokens`는 미지원이며 Claude Code inference fallback 사용

## 8. Token logging 검증

정상 종료한 요청 후 Log Analytics에서 확인합니다.

```bash
workspace_id="$(
  terraform -chdir=infra/environments/claude-standard-v2 \
    output -raw log_analytics_workspace_id
)"

az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query '
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(1h)
| summarize arg_max(TimeGenerated, *) by CorrelationId
| project TimeGenerated, CorrelationId, ModelName, PromptTokens, CompletionTokens, TotalTokens, IsStreamCompletion
| order by TimeGenerated desc
'
```

Application Insights에는 `llm-emit-token-metric`이 다음 dimension으로 기록됩니다.

- API ID
- requested model
- Keycloak `iss:sub`의 SHA-256 user hash
- APIM subscription ID
- APIM subscription name

raw JWT subject와 subscription key 값은 기록하지 않습니다. 사용자 API는 Keycloak 인증을
유지하며 Workbook에서 `SubscriptionId=none`으로 표시됩니다. 서비스 API 요청은
`service-claude-gateway` API-scoped subscription ID와 이름으로 집계됩니다.

cached input은 `AppMetrics`의 `Prompt Cached Tokens`에서 확인합니다.

동일한 prompt를 연속 호출해 cache read를 검증할 때 첫 cache 생성 직후에는 전파가 완료되지
않아 다시 cache creation이 발생할 수 있습니다. 동일한 요청을 약 20초 후 재시도하여
`cache_read_input_tokens`와 `Prompt Cached Tokens`를 비교합니다.

```bash
az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query '
AppMetrics
| where TimeGenerated > ago(1h)
| where Name in ("Prompt Tokens", "Prompt Cached Tokens", "Completion Tokens")
| extend dimensions=parse_json(Properties)
| summarize Tokens=sum(Sum)
    by Name,
       Model=tostring(dimensions.Model),
       UserHash=tostring(dimensions["User Hash"]),
       SubscriptionId=tostring(dimensions["Subscription ID"]),
       SubscriptionName=tostring(dimensions["Subscription Name"])
'
```

Workbook은 `model_pricing_dbu_per_million`의 uncached input, output, cached input DBU 소비율과
`databricks_dbu_price_usd`를 사용해 모델·사용자·subscription별 추정 DBU/USD를 계산합니다.
현재 APIM preview metric은 `cache_creation_input_tokens`를 cache-write metric으로 내보내지
않으므로 추정 비용에는 cache write 비용이 포함되지 않습니다.

Prompt와 completion 본문은 Azure Monitor/Application Insights 양쪽에서 기본 0 byte로
수집하지 않습니다. 중단된 stream은 backend usage가 도착하지 않아 token이 없거나 부정확할 수
있습니다. 사용자 dimension은 APIM 제한상 값 100개, metric namespace는 active time series
1,000개 제한의 영향을 받으므로 custom metric은 운영 추세용이며 감사 또는 과금 원장으로
사용하지 않습니다.

## 9. Claude Code URL 전환

`claude_gateway_base_url` output을
사용자에게 전달하고 [README의 Claude Code 설정](../README.md#claude-code)에 따라 Claude
Code만 신규 URL로 전환합니다.



## Microsoft 공식 문서

- [APIM v2 tier 개요](https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview)
- [Standard v2 outbound VNet integration](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound)
- [APIM LLM logs](https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs)
- [llm-emit-token-metric policy](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy)
- [APIM Application Insights 통합](https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights)
- [StandardV2 NAT Gateway](https://learn.microsoft.com/azure/nat-gateway/nat-sku)
- [APIM Managed Identity 인증](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [Databricks prompt caching](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/score-foundation-models#prompt-caching)
- [Databricks model serving DBU 소비율](https://learn.microsoft.com/azure/databricks/resources/pricing#model-serving-sku)
- [Azure Storage network security](https://learn.microsoft.com/azure/storage/common/storage-network-security-overview)
- [Network Security Perimeter](https://learn.microsoft.com/azure/private-link/network-security-perimeter-concepts)
