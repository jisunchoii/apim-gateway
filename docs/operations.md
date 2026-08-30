# LLM Gateway 운영 문서

> 고객 연결 방법과 API 사용 예시는 [고객 사용 안내](../README.md)를 참고합니다.
> Claude Code에서 GPT/OSS 모델을 쓰는 전체 구축은
> [온보딩 가이드](claude-code-gpt-oss-onboarding.md)를 참고합니다.
> 아래 명령은 별도 설명이 없으면 저장소 루트에서 실행합니다.

APIM 앞단에서 OIDC 토큰을 검증하고, 라우팅된 모델만 통과시키고, 사용자별 토큰 사용량을 집계하는
OpenAI 호환 LLM 게이트웨이입니다.

제한이 목적이 아니라 **가시성**이 목적입니다. 예산 차단·모델 강등은 넣지 않았으며,
레이트 리밋은 기본적으로 꺼져 있습니다(`user_tokens_per_minute = 0`).

## 이름 체계

- **LLM Gateway**는 제품과 Workbook의 표시 이름입니다.
- `prefix`는 Azure resource name에 사용하는 환경별 짧은 이름입니다. 기본값은 `llmgw` 입니다.
- `trace_source`는 Azure Monitor trace 구분자입니다. 신규 기본값은 `llm-gateway`이며 운영 KQL은
  문자열을 하드코딩하지 않고 Terraform output을 사용합니다.
- 저장소 디렉터리 이름은 Azure resource name이나 trace source 계약에 포함되지 않습니다.

## 거버넌스 5개

| 관심사 | 구현 | 변경 방법 |
|---|---|---|
| 인증 | 최종 사용자 `validate-jwt`, 서비스 계정 API-scoped subscription | tfvars `oidc_provider` / APIM subscription |
| 인가 | `required-claims`로 OIDC `scope`와 role claim 검증 | tfvars `required_scope`, `required_role` / provider 사용자 관리 |
| 모델 라우팅 | `routed_models`별 backend 선택, 미지원 모델 403 | Terraform |
| 사용량·비용 | resource log 2개 테이블 조인 + Workbook | Terraform / Azure Monitor |
| 백엔드 보호 | 모델별 backend circuit breaker (429) | `main.tf` |

최종 사용자 API에서 APIM은 discovery document의 서명 키와 issuer, `aud=llm-gateway-api`,
`scope=llm-gateway`, `llm_gateway_roles=invoke`를 모두 확인합니다. OIDC provider는 Gateway
사용이 승인된 사용자의 access token에 이 claim 계약을 제공해야 합니다. Terminal client는
public client이며 Device Authorization Grant를 사용합니다. 서비스 API는 사용자 OIDC provider를
거치지 않고 APIM이 API 범위 subscription key를 검증합니다.

### APIM policy 처리 순서

1. 최종 사용자 API는 OIDC JWT를 검증하고, 서비스 API는 APIM subscription을 검증합니다.
2. 클라이언트가 전달한 API key와 APIM 구독 키를 제거합니다.
3. 사용자 `iss:sub` 또는 서비스 subscription ID 기반 가명 ID와 표시 label을 trace에 기록합니다.
4. JSON 본문과 `model` 필드를 검증하고 지원하지 않는 모델은 `403`으로 종료합니다.
5. Chat Completions와 Responses 요청 형식을 Foundry backend에 맞게 정규화합니다.
6. 설정된 경우 사용자·모델별 token rate limit을 적용합니다.
7. 선택한 backend에 맞는 관리 ID token으로 Authorization header를 교체합니다.
8. streaming 응답을 buffering하지 않고 클라이언트로 전달합니다.

## 배포

### 준비

| 항목 | 준비 사항 |
|---|---|
| 도구 | Azure CLI, Terraform, Bash, Python 3, Node.js |
| Azure 인증 | `az login`을 실행하고 배포 대상 구독을 선택합니다. |
| OIDC provider | [Okta 가이드](okta-admin-guide.md)의 구성을 완료합니다. |
| Terraform 입력 | `terraform.tfvars.example`을 복사하고 환경 값을 입력합니다. |

```bash
az login
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

### 1. Terraform state

**신규 환경은 Azure Blob remote state를
기본으로 생성**하며, 첫 `terraform init` 전에 반드시 bootstrap을 실행합니다. 스크립트가
Entra ID 인증을 사용하는 ignore된 `infra/backend.tf`를 생성하므로 shared key나 access key는
사용하지 않습니다.

```bash
./scripts/bootstrap-backend.sh
terraform -chdir=infra init
```

스크립트는 현재 `az login`한 사용자에게 state 읽기·쓰기 권한을 자동으로 부여합니다. CI나
여러 운영자에게 추가 권한을 부여하는 고급 설정은 스크립트의 `STATE_CONTRIBUTORS` 옵션을
사용합니다.

Storage Account 이름은 현재 subscription ID와 `prefix`, `env`, `location`을 해시하여
결정적으로 생성합니다. 같은 입력으로 다시 실행하면 같은 account를 재사용하며, 기존
`backend.tf`와 계산 결과가 다르면 state를 자동으로 전환하지 않고 중단합니다. 운영자 PC에서
접근할 수 있도록 public network endpoint는 활성화하지만 anonymous blob access와 Shared Key
인증은 비활성화합니다.

기존 local-state 환경은 명시적인 migration 작업을 승인받기 전까지 이 절차를 실행하지 않습니다.
스크립트도 `infra/terraform.tfstate`가 존재하면 Azure 리소스를 만들기 전에 중단합니다. 승인된
migration에서만 state를 백업한 뒤 `ALLOW_LOCAL_STATE_MIGRATION=true`를 명시합니다.
`-backend=false`는 CI의 정적 `terraform validate`처럼 state를 사용하지 않는 검사에만
사용합니다.

### 2. 배포

state 초기화가 끝난 후 배포합니다.

```bash
terraform -chdir=infra plan
terraform -chdir=infra apply
```

배포 후 base URL은 인증 방식별로 분리됩니다.

```bash
terraform -chdir=infra output -raw gateway_base_url
terraform -chdir=infra output -raw service_gateway_base_url
```

### 서비스 계정 subscription

서비스마다 `service-model-gateway` API 범위의 standalone subscription을 하나씩 생성합니다.
Terraform은 subscription key를 state에 저장하지 않도록 API까지만 관리합니다.

Azure Portal에서 **API Management → Subscriptions → Add subscription**을 선택하고 다음처럼
생성합니다.

| 항목 | 값 |
|---|---|
| Name / Display name | 서비스 식별자 |
| Scope | API → `Service Model Gateway` |
| User | 비워서 standalone subscription으로 생성 |

서비스에는 primary 또는 secondary key 하나만 전달합니다. GitHub Actions에서는 repository 또는
environment secret에 `LLMGW_SUBSCRIPTION_KEY`로 저장하고, Azure 워크로드에서는
[Azure Key Vault](https://learn.microsoft.com/azure/key-vault/general/overview)에 저장한 뒤
실행 시 환경변수로 주입합니다. 요청은 `Ocp-Apim-Subscription-Key` header를 사용하며 사용자 OIDC
bearer token은 필요하지 않습니다. 서비스별 사용량과 제한 counter는 subscription ID 기준으로
분리되고 Workbook에는 subscription 이름이 사용자 label로 표시됩니다.

키 회전은 secondary key를 재생성해 서비스에 배포하고 전환을 확인한 뒤 primary key를
재생성하는 순서로 수행합니다. built-in all-access subscription과 여러 서비스가 공유하는
subscription은 사용하지 않습니다.

관련 공식 문서:
[APIM subscriptions](https://learn.microsoft.com/azure/api-management/api-management-subscriptions),
[subscription 생성](https://learn.microsoft.com/azure/api-management/api-management-howto-create-subscriptions),
[primary key 재생성](https://learn.microsoft.com/rest/api/apimanagement/subscription/regenerate-primary-key),
[secondary key 재생성](https://learn.microsoft.com/rest/api/apimanagement/subscription/regenerate-secondary-key).

### 모델 관리

| 변수 | 용도 |
|---|---|
| `model_deployments` | 이 Terraform이 생성하고 관리하는 모델 배포 |
| `project_model_deployments` | 다른 Foundry 프로젝트에 이미 존재하는 모델 연결 |
| `managed_foundry_account_enabled` | `null` 자동 생성, `true` 빈 계정 유지, `false` 관리형 계정 비활성화 |
| `routed_models` | APIM policy가 요청을 전달할 모델 목록 |

`routed_models`를 생략하면 배포된 모든 모델을 라우팅합니다.
각 deployment의 `opencode_api`는 `responses` 또는 `chat`이며, 관리형 모델은 Responses,
기존 프로젝트 모델은 Chat이 기본값입니다. 기존 프로젝트의 GPT 모델처럼 Responses를 사용해야
하면 해당 항목에 `opencode_api = "responses"`를 지정합니다.

`model_deployments = {}`이고 `managed_foundry_account_enabled = null`이면 Gateway 전용 Foundry
계정을 생성하지 않습니다. 나중에 `model_deployments`에 첫 모델을 추가하면 같은 apply에서 계정,
RBAC, 모델 배포와 APIM backend를 생성합니다. 마지막 관리형 모델을 제거한 뒤 빈 계정을 유지하려면
제거 전에 `managed_foundry_account_enabled = true`를 적용합니다.

**모델 추가**

1. `model_deployments` 또는 `project_model_deployments`에 추가합니다.
2. `routed_models`를 사용 중이면 같은 모델 이름을 추가합니다.
3. `terraform plan`을 확인하고 `terraform apply`를 실행합니다.

**모델 제거**

1. `routed_models`에서 제거하고 `terraform apply`를 실행합니다.
2. deployment map에서 제거하고 다시 `terraform apply`를 실행합니다.

두 단계로 나누면 APIM policy가 backend를 참조하는 동안 backend가 먼저 삭제되는 문제를
방지할 수 있습니다.

### 배포와 Model Gateway Registry 자동 갱신

일반 배포는 repository root에서 다음 wrapper를 사용합니다.

```bash
bash ./scripts/deploy.sh
```

Wrapper는 저장된 plan을 만든 뒤 정확히 그 plan을 apply하고, 성공한 Terraform state의
`api_catalog_manifest` output으로 `docs/model-gateway-registry.html`을 갱신합니다.
모델 이름, format/version, SKU/capacity, API 경로, APIM Backend ID/URL, Managed Identity
audience와 RBAC가 Terraform에서 HTML로 전달되므로 Excel은 생성 pipeline에 포함되지 않습니다.
apply 없이 plan만 확인할 때는 `bash ./scripts/deploy.sh --plan-only`을 사용합니다.

APIM management API는 저장된 policy XML의 들여쓰기, attribute quote와 일부 줄바꿈을
canonical format으로 다시 serialize합니다. 따라서 refresh 후 plan에 두 API policy의 formatting
update가 보일 수 있지만 route, audience와 body가 같으면 의미상 변경은 아닙니다.

Gateway 전용 Foundry account가 OpenAI와 Fireworks 모델을 함께 호스팅하므로 APIM Managed
Identity는 resource scope의 `Cognitive Services User` 역할과 `https://ai.azure.com` audience를
사용합니다.

### 기존 Foundry 프로젝트 모델 연결

Terraform은 기존 프로젝트의 endpoint를 조회하고 APIM Managed Identity에 `Foundry User` 역할을
부여합니다. 원본 모델 배포는 생성, 변경 또는 삭제하지 않습니다.

```hcl
project_model_deployments = {
  "existing-model" = {
    project_resource_id = "/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>"
    capacity_tpm        = 500000
    opencode_api        = "responses"
  }
}
```

`capacity_tpm`은 원본 배포의 실제 TPM을 Workbook에 표시하기 위한 값입니다. 원본 배포 용량이
변경되면 이 값도 함께 갱신해야 합니다.

## APIM autoscale

`infra/autoscale.tf`가 Capacity 메트릭 기반 autoscale을 관리합니다.

- 유닛 범위: 1~3, 기본 1 (tfvars `apim_sku = "Premium_1"`과 일치)
- Scale-out: Capacity 평균 > 50%가 5분 지속 시 +1유닛, cooldown 20분
- Scale-in: Capacity 평균 < 30%가 60분 지속 시 -1유닛, cooldown 60분

유닛 변경은 15분 이상 걸리므로 순간 burst 대응은 기존처럼 429와 `Retry-After`가 담당합니다.
Autoscale이 유닛을 늘린 상태에서 `terraform apply`를 실행하면 tfvars 기준 1유닛으로
되돌아가므로, 피크 시간대의 apply는 피하거나 apply 전 현재 유닛 수를 확인합니다.

## 거버넌스 Workbook

Terraform이 `LLM Gateway Governance` Azure Monitor Workbook을 Log Analytics workspace에 같이
배포합니다. 별도 KQL 실행 없이 다음 URL을 열면 됩니다.

```bash
cd infra
terraform output -raw governance_workbook_portal_url
```

Azure Portal에서는 **Monitor → Workbooks → LLM Gateway Governance**에서도 찾을 수 있습니다.
Workbook은 선택한 시간 범위에 대해 다음을 한 화면에 표시합니다.

- Overview: 활성 사용자, 요청, prompt/completion/total token, 예상 비용, 성공률, p95
- Users: Top 10, 사용자별 점유율·모델·오류·p95, peak RPM/TPM, burst와 사용자 제한 사용률
- Capacity: 모델별 TPM 한도·peak·headroom, 429/503, APIM Capacity/CPU/Memory, latency
- Governance: 401/400/403, 미지원 모델 시도, rate limit, backend 오류, operation별 사용량

비용은 Azure 청구 API가 아니라 `infra/terraform.tfvars`의 모델별 유효 단가로 계산합니다.
단가를 모르면 0으로 두며, 이 경우 사용량은 정상 표시되고 예상 비용만 0입니다.

```hcl
# infra/terraform.tfvars
model_pricing_usd_per_million = {
  "gpt-5.6-sol" = {
    input  = 0 # 실제 계약 input 1M-token 단가
    output = 0 # 실제 계약 output 1M-token 단가
  }
  "gpt-5.6-terra" = {
    input  = 0
    output = 0
  }
  "gpt-5.6-luna" = {
    input  = 0
    output = 0
  }
  "FW-GLM-5.2" = {
    input  = 0
    output = 0
  }
  "FW-Kimi-K3" = {
    input  = 0
    output = 0
  }
}
```

값을 변경한 뒤 `terraform apply`를 실행하면 Workbook의 비용 계산식에 반영됩니다.

Workbook은 OIDC user label을 표시하고 동일 사용자의 안정적인 집계·join에는 64자 해시를
사용합니다. user label claim이 없는 과거 로그는 해시 앞 12자리로 표시됩니다. 401은 JWT 검증
전에 종료되므로 anonymous가 정상이며, 인증된 400/403은 정책 trace를 검증보다 먼저 기록해
사용자에게 귀속합니다. APIM
Capacity 차트는 Azure Monitor Metrics를 직접 조회합니다. Gateway CPU/Memory metric은 APIM v2
SKU 전용이므로 현재 classic SKU에서는 Capacity만 표시됩니다.

관련 공식 문서:
[Azure Workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview),
[APIM resource logs](https://learn.microsoft.com/azure/api-management/api-management-howto-use-azure-monitor),
[APIM metrics](https://learn.microsoft.com/azure/api-management/api-management-howto-use-azure-monitor#metrics).

## 원시 로그와 사용자별 토큰 집계

토큰 수는 `ApiManagementGatewayLlmLog`, 사용자는 정책의 `trace`가 남기는
`ApiManagementGatewayLogs.TraceRecords`에 들어갑니다. 둘은 `CorrelationId`로 조인합니다.

집계 키는 OIDC token의 `iss:sub`를 SHA-256으로 해시한 값입니다. Workbook 표시용으로는
`oidc_provider.user_label_claim`의 username을 별도 `userLabel` metadata에 기록합니다.
email과 원본 subject는 로그에 남기지 않습니다. username도 식별 정보이므로 Log Analytics와
Workbook 접근 권한 및 보존 기간을 제한합니다.

`TraceSource`는 현재 환경의 Terraform output에서 읽습니다.

```bash
TRACE_SOURCE="$(terraform -chdir=infra output -raw trace_source)"
WORKSPACE_ID="$(terraform -chdir=infra output -raw log_analytics_workspace_id)"
QUERY=$(cat <<KQL
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(1d) and TotalTokens > 0
| summarize PromptTokens=max(PromptTokens), CompletionTokens=max(CompletionTokens)
    by CorrelationId, ModelName
| join kind=inner (
    ApiManagementGatewayLogs
    | where TimeGenerated > ago(1d)
    | mv-expand TraceRecords
    | extend
        userId = tostring(TraceRecords.metadata.userId),
        userLabel = tostring(TraceRecords.metadata.userLabel)
    | where tostring(TraceRecords.source) == "${TRACE_SOURCE}" and isnotempty(userId)
    | extend userLabel = iff(isempty(userLabel), substring(userId, 0, 12), userLabel)
    | summarize userId=any(userId), userLabel=any(userLabel) by CorrelationId
) on CorrelationId
| summarize PromptTokens=sum(PromptTokens), CompletionTokens=sum(CompletionTokens)
    by userLabel, userId, ModelName
KQL
)
az monitor log-analytics query --workspace "$WORKSPACE_ID" --analytics-query "$QUERY" -o table
```

집계가 신뢰할 만한지 먼저 확인합니다. 스트리밍 응답에서 `stream_options.include_usage`를 정책이
주입하지만, 클라이언트가 응답을 중간에 끊으면 usage 청크가 도착하지 않아 토큰이 0으로 남습니다.
코딩 에이전트는 취소가 잦으므로 이 비율이 높으면 위 숫자는 하한선으로만 해석합니다.
정확한 chargeback 근거로 사용하려면 이 값을 먼저 확인해야 합니다. 문서에 명시된 수치는 없으며
실측해야 합니다.

```kusto
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(1d)
| summarize TotalTokens=max(TotalTokens) by CorrelationId
| summarize blind = countif(TotalTokens == 0), total = count()
| extend blind_pct = iff(total == 0, 0.0, round(100.0 * blind / total, 1))
```

`trace`는 App Insights 샘플링의 영향을 받지 않아 전량 기록됩니다. 커스텀 메트릭
(`llm-emit-token-metric`)은 사용하지 않습니다. 포털 전용 설정이 필요하고, GA 예정이 없는
preview이며, 50,000개 time series 상한이 있고, 문서상 감사 용도로 사용할 수 없다고 명시되어
있기 때문입니다.

## 네트워크

VNet·private endpoint·jumpbox는 사용하지 않습니다. classic APIM은 인터넷 백엔드로 나갈 때
**고정 공인 IP**를 사용합니다. Foundry 네트워크 방화벽은 모든 요청을 기본적으로 차단하고
APIM의 공인 IP에서 들어오는 요청만 허용합니다. 또한 API key 인증을 비활성화하므로, 허용된
IP에서 접근하더라도 APIM Managed Identity와 Azure RBAC 권한이 있어야 모델을 호출할 수 있습니다.

주의: 이 IP는 인스턴스를 재생성하거나 VNet, 서브넷 또는 가용영역을 변경하면 달라집니다.
이 경우 `apply`를 다시 실행해 `ip_rules`를 갱신합니다.

## TPM

`capacity`는 천 단위 TPM이며 **지역에 이미 승인된 쿼터를 넘으면 `apply`가 실패**합니다.

example은 모델 버전을 `NoAutoUpgrade`로 고정합니다. `GlobalStandard`는 높은 가용 쿼터를
제공하지만 추론 처리가 리소스 지역 밖에서 이뤄질 수 있으므로, 데이터 경계 요구가 있으면 SKU를
별도로 결정해야 합니다.

```bash
az cognitiveservices usage list --location <region> --output table
```
