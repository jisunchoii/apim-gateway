# Claude Code에서 GPT/OSS Foundry 모델 사용하기

이 문서는 이 저장소를 처음 사용하는 고객이 Azure, Microsoft Foundry, API Management, Okta,
Claude Code까지 한 번에 구축하기 위한 한국어 가이드입니다.

Microsoft 공식 Claude Code 연동은 Foundry의 Anthropic endpoint로 **Claude 모델**을 붙이는
경로입니다. 이 저장소는 GPT 및 OSS 모델을 Claude Code에서 쓰기 위해 OpenCodex가
`POST /v1/messages`를 APIM의 Responses 또는 Chat Completions로 변환합니다. 공식 지원과
같은 수준을 주장하지 않으며, 실험적/community 경로입니다.

공식 경로: [Configure Claude Code for Microsoft Foundry](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-claude-code)

## 목차

1. [지원 범위와 아키텍처](#1-지원-범위와-아키텍처)
2. [사전 요구 사항](#2-사전-요구-사항)
3. [Azure 구독, 권한, region, quota](#3-azure-구독-권한-region-quota)
4. [Okta 구성](#4-okta-구성)
5. [terraform.tfvars 작성](#5-terraformtfvars-작성)
6. [GPT와 OSS 모델 연결](#6-gpt와-oss-모델-연결)
7. [Terraform 배포](#7-terraform-배포)
8. [배포 검증과 client_profile](#8-배포-검증과-client_profile)
9. [고객 PC 설치](#9-고객-pc-설치)
10. [연결 값 설정](#10-연결-값-설정)
11. [Claude Code 실행과 최초 로그인](#11-claude-code-실행과-최초-로그인)
12. [모델, streaming, tool 확인](#12-모델-streaming-tool-확인)
13. [장애 대응](#13-장애-대응)
14. [정리](#14-정리)
15. [설정 책임표](#15-설정-책임표)

운영(Workbook, KQL, 모델 추가/삭제 순서)은 [운영 문서](operations.md)를 참고합니다.
Okta Admin Console 화면 절차는 [Okta 관리자 가이드](okta-admin-guide.md)를 참고합니다.

## 1. 지원 범위와 아키텍처

### 이 경로가 하는 일

- APIM이 `/openai/v1/responses`와 `/openai/v1/chat/completions`를 제공합니다.
- APIM은 Anthropic `POST /v1/messages`를 직접 제공하지 않습니다.
- Claude Code 요청은 로컬 OpenCodex가 모델별로 Responses 또는 Chat으로 변환합니다.
- 사용자 인증은 Okta Device Authorization Grant입니다. client secret을 고객 PC에 두지 않습니다.
- APIM은 사용자 JWT를 검증한 뒤 제거하고, Foundry에는 APIM Managed Identity만 보냅니다.

Microsoft 문서:

- [Authenticate and authorize LLM APIs with APIM](https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis)
- [APIM `validate-jwt`](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [APIM managed identity authentication](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [Foundry model endpoints](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/endpoints)

### 프로비저닝

```text
고객 관리자
  ├─ Okta Custom Authorization Server + Native OIDC App
  ├─ Foundry 모델 배포 또는 기존 프로젝트 모델 연결
  └─ Terraform
       ├─ APIM + 사용자 API
       ├─ 모델별 backend와 routed_models policy
       ├─ APIM Managed Identity에 Foundry inference RBAC
       └─ 비밀이 아닌 client_profile 출력
```

### 런타임

```text
Claude Code
  │ POST /v1/messages
  ▼
OpenCodex  127.0.0.1:10100
  │ GPT/Responses 호환 → /responses
  │ Responses 미지원 OSS → /chat/completions
  ▼
인증 프록시  127.0.0.1:10101
  │ Okta access token 주입
  ▼
Azure API Management
  │ 1. JWT 서명, issuer, audience, scope, role 검증
  │ 2. routed_models allowlist로 backend 선택
  │ 3. 사용자 Authorization 제거
  │ 4. Managed Identity 토큰으로 교체
  ▼
Microsoft Foundry deployment
```

보안 경계: 사용자 Okta token은 APIM까지만 전달됩니다. Foundry는 APIM Managed Identity만
신뢰합니다.

APIM은 **한 번에 하나의** 최종 사용자 OIDC provider만 검증합니다. 다른 IdP 값으로 apply하면
라이브 JWT 설정이 그 provider로 바뀝니다.

## 2. 사전 요구 사항

공통:

| 도구 | 최소 |
|---|---|
| Git | clone 가능 |
| Azure CLI | `az login` 가능 |
| Terraform | `>= 1.11` |
| Node.js | `>= 20` (`package.json` `engines`) |
| npm | Node와 함께 설치 |
| Claude Code CLI | `claude`가 PATH에 있어야 함 |

OpenCodex는 따로 global 설치하지 않습니다. 저장소에서 `npm ci`가 `@bitkyc08/opencodex@2.28.0`을
설치합니다.

`scripts/bootstrap-backend.sh`, `scripts/deploy.sh`, `scripts/smoke-test.sh`는 Bash 전용입니다.
Windows에서는 Git Bash 또는 WSL이 필요합니다. 아래 canonical 절차는 `az`, `terraform`, `npm`을
중심으로 적습니다.

## 3. Azure 구독, 권한, region, quota

1. 배포 구독과 Entra ID 테넌트를 정합니다.
2. `az login` 후 구독을 선택합니다.
3. `location`은 Terraform이 요구하는 canonical 소문자 이름입니다. 예: `eastus2`.
4. 사용할 모델이 그 region에서 배포 가능한지 Foundry catalog와 quota를 확인합니다.

```bash
az account set --subscription "<subscription-id>"
az cognitiveservices usage list --location eastus2 --output table
```

권한 개요:

- 배포 운영자: 리소스 그룹 생성, APIM, Foundry/Cognitive Services, Log Analytics, 역할 할당
- APIM system-assigned identity: Terraform이 Foundry에 inference 역할을 부여합니다.
  관리형 계정은 `https://cognitiveservices.azure.com`, 기존 프로젝트 모델은
  `https://ai.azure.com` audience를 사용합니다.

## 4. Okta 구성

상세 화면 절차는 [Okta 관리자 가이드](okta-admin-guide.md)입니다. 요약:

1. Custom Authorization Server를 만들고 audience를 `llm-gateway-api`로 둡니다.
2. scope `llm-gateway`를 추가합니다.
3. access token claim:
   - `llm_gateway_roles`: `invoke` 그룹
   - `llm_gateway_user`: 사용자 표시 이름
4. Native OIDC application에서 Device Authorization과 Refresh Token을 켭니다.
   client secret을 쓰지 않습니다.
5. 테스트 사용자를 `invoke` 그룹에 넣습니다.

기록할 값:

```text
https://<okta-domain>/oauth2/<authorization-server-id>
https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration
<native-app-client-id>
```

Claude 경로 scope는 `openid offline_access llm-gateway`입니다. refresh token이 필요합니다.

참고: [Okta Device Authorization Grant](https://developer.okta.com/docs/guides/device-authorization-grant/main/)

## 5. terraform.tfvars 작성

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

`infra/terraform.tfvars`는 gitignore 대상입니다. 저장소에 커밋하지 않습니다.

필수에 가까운 값:

| 변수 | 역할 |
|---|---|
| `prefix`, `env`, `location` | 리소스 이름 |
| `owner`, `cost_center` | 태그 |
| `trace_source` | 운영 로그 구분자 |
| `apim_sku` | 기본 `Premium_1` |
| `oidc_provider` | APIM JWT와 클라이언트 연결 |
| `model_deployments` 또는 `project_model_deployments` | 모델 |
| `routed_models` | APIM allowlist |

Okta `oidc_provider` 예:

```hcl
oidc_provider = {
  openid_config_url = "https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"
  audience          = "llm-gateway-api"
  issuer            = "https://<okta-domain>/oauth2/<authorization-server-id>"
  client_id         = "<okta-native-app-client-id>"
  client_scope      = "openid offline_access llm-gateway"
  required_scope    = "llm-gateway"
  scope_claim       = "scp"
  role_claim        = "llm_gateway_roles"
  required_role     = "invoke"
  user_label_claim  = "llm_gateway_user"
}
```

Okta access token의 scope claim은 보통 `scp`입니다. `oidc_provider.scope_claim`과 맞춥니다.

## 6. GPT와 OSS 모델 연결

Foundry 요청의 `model` 값은 모델 카탈로그 ID가 아니라 **deployment name**입니다. 이 저장소는
deployment name과 고객에게 보이는 모델 이름을 같게 유지합니다.

두 가지 연결 방식:

| 변수 | 용도 |
|---|---|
| `model_deployments` | 이 스택이 Foundry 계정과 deployment를 만듦. 기본 protocol `responses` |
| `project_model_deployments` | 기존 Foundry 프로젝트의 배포를 참조만 함. 기본 protocol `chat` |

같은 이름을 두 map에 동시에 넣을 수 없습니다.

`opencode_api`는 GPT/OSS 브랜드가 아니라 **실제 API capability**로 고릅니다.

- Responses를 지원하면 `opencode_api = "responses"`를 우선합니다.
- Responses가 `400 Model not supported`이면 `opencode_api = "chat"`으로 둡니다.
- `routed_models`에 없는 이름은 APIM이 `403`을 반환합니다.

예: GPT는 Responses, OSS는 Chat.

```hcl
project_model_deployments = {
  "gpt-5.6-sol" = {
    project_resource_id = "/subscriptions/.../accounts/.../projects/..."
    capacity_tpm        = 500000
    opencode_api        = "responses"
  }
  "FW-Kimi-K3" = {
    project_resource_id = "/subscriptions/.../accounts/.../projects/..."
    capacity_tpm        = 300000
    opencode_api        = "chat"
  }
}

routed_models = [
  "gpt-5.6-sol",
  "FW-Kimi-K3",
]
```

선택 필드 `context_window`, `tools`, `streaming`은 클라이언트 catalog 메타데이터입니다.
값을 추측해서 넣지 않습니다. 공급자가 명시한 경우에만 설정합니다. `context_window`가 200,000을
넘으면 OpenCodex가 Claude Code `autoContext`를 켭니다.

프로젝트 resource ID:

```bash
az cognitiveservices account project show \
  --name <foundry-resource-name> \
  --project-name <project-name> \
  --resource-group <resource-group-name> \
  --query id -o tsv
```

## 7. Terraform 배포

신규 환경은 첫 `terraform init` 전에 Azure Blob remote state를 만듭니다.

Bash / Git Bash / WSL:

```bash
az login
./scripts/bootstrap-backend.sh
terraform -chdir=infra init
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

Windows PowerShell에서 wrapper 없이 진행할 때는 Git Bash/WSL에서 bootstrap을 실행한 뒤,
같은 디렉터리에서 `terraform` 명령을 사용합니다. 기존 local-state 환경에는 승인 없이
bootstrap을 실행하지 않습니다.

`oidc_provider`가 의도한 Okta 값인지 plan에서 확인합니다. 다른 IdP로 바뀌는 diff가 있으면
apply하지 않습니다.

## 8. 배포 검증과 client_profile

```bash
terraform -chdir=infra output -json client_profile
terraform -chdir=infra output routed_models
terraform -chdir=infra output gateway_base_url
```

`client_profile`은 token이 없는 연결 문서입니다. 고객 PC에 파일로 전달합니다. 이 저장소에는
커밋하지 않습니다.

```bash
terraform -chdir=infra output -json client_profile > client-profile.json
```

포함 내용: `gateway_base_url`, OIDC discovery/client_id/scope, 모델 이름과 `api`
(`responses` 또는 `chat`), 선택적 capability.

고객 PC는 Terraform state를 읽지 않습니다. `LLMGW_CLIENT_PROFILE` 또는 환경 변수를 사용합니다.

APIM JWT와 Managed Identity 동작은 Microsoft 문서와 같습니다.

- [Import a Microsoft Foundry API into APIM](https://learn.microsoft.com/azure/api-management/azure-ai-foundry-api)
- [Managed identity for Azure OpenAI in Foundry](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/managed-identity)

## 9. 고객 PC 설치

1. Claude Code CLI를 설치하고 `claude --version`이 동작하는지 확인합니다.
2. Node.js 20 이상을 설치합니다.
3. 이 저장소를 clone합니다.
4. 저장소 루트에서 의존성을 설치합니다.

```bash
git clone <repository-url>
cd apim-gateway
npm ci
```

`npm ci`가 pinned OpenCodex를 설치합니다. `npm install -g opencodex`를 실행하지 않습니다.

## 10. 연결 값 설정

우선순위:

1. 환경 변수 (`LLMGW_BASE_URL`, `LLMGW_OIDC_*`, 모델 목록)
2. `LLMGW_CLIENT_PROFILE` 파일
3. 운영자 PC에서만, `terraform output -json client_profile`

권장: 운영자가 만든 `client-profile.json`을 고객에게 전달합니다.

PowerShell:

```powershell
$env:LLMGW_CLIENT_PROFILE = "C:\path\to\client-profile.json"
```

Bash / zsh:

```bash
export LLMGW_CLIENT_PROFILE="$HOME/client-profile.json"
```

파일이 없으면:

PowerShell:

```powershell
$env:LLMGW_BASE_URL = "https://<apim-name>.azure-api.net/openai/v1"
$env:LLMGW_OIDC_DISCOVERY_URL = "https://<okta-domain>/oauth2/<id>/.well-known/openid-configuration"
$env:LLMGW_OIDC_CLIENT_ID = "<native-app-client-id>"
$env:LLMGW_OIDC_SCOPE = "openid offline_access llm-gateway"
$env:LLMGW_CLAUDE_RESPONSES_MODELS = "gpt-5.6-sol"
$env:LLMGW_CLAUDE_CHAT_MODELS = "FW-Kimi-K3"
$env:LLMGW_CLAUDE_DEFAULT_MODEL = "gpt-5.6-sol"
```

Bash / zsh:

```bash
export LLMGW_BASE_URL="https://<apim-name>.azure-api.net/openai/v1"
export LLMGW_OIDC_DISCOVERY_URL="https://<okta-domain>/oauth2/<id>/.well-known/openid-configuration"
export LLMGW_OIDC_CLIENT_ID="<native-app-client-id>"
export LLMGW_OIDC_SCOPE="openid offline_access llm-gateway"
export LLMGW_CLAUDE_RESPONSES_MODELS="gpt-5.6-sol"
export LLMGW_CLAUDE_CHAT_MODELS="FW-Kimi-K3"
export LLMGW_CLAUDE_DEFAULT_MODEL="gpt-5.6-sol"
```

기본 포트: OpenCodex `10100`, 인증 프록시 `10101`. 충돌 시
`LLMGW_OPENCODEX_PORT`, `LLMGW_AUTH_PROXY_PORT`(구 `LLMGW_OKTA_PROXY_PORT`).

전용 홈은 사용자 기본 `~/.claude`를 건드리지 않습니다.

| 항목 | Windows | macOS / Linux |
|---|---|---|
| OpenCodex profile | `%USERPROFILE%\.llmgw\opencodex-okta` | `~/.llmgw/opencodex-okta` |
| token cache | `%USERPROFILE%\.llmgw\okta-claude-token.json` | `~/.llmgw/okta-claude-token.json` |

## 11. Claude Code 실행과 최초 로그인

저장소 루트:

```bash
npm run claude
```

이 명령이 하는 일:

1. APIM catalog(또는 환경 변수)로 전용 OpenCodex config를 씁니다.
2. 전용 Claude settings에 SessionStart hook을 등록합니다.
3. OpenCodex를 loopback에서 기동하고 health를 확인합니다.
4. `ocx claude`로 Claude Code를 시작합니다.
5. SessionStart hook이 Okta Device Flow와 인증 프록시를 준비합니다.

최초 세션만 브라우저에서 user code를 승인합니다. 이후는 refresh token으로 갱신합니다.
요청 경로의 APIM 401은 브라우저 로그인을 열지 않습니다. `login_required`이면
`npm run claude`를 다시 실행해 로그인합니다.

| 명령 | 동작 |
|---|---|
| `npm run claude` | 설정 후 Claude Code 시작 (기본) |
| `npm run claude:configure` | OpenCodex/Claude 설정만 생성 |
| `npm run claude:doctor` | 비밀 없이 Node, Claude, OpenCodex, OIDC, 포트 확인 |
| `npm run claude:restart` | 로컬 서비스를 종료한 뒤 다시 시작 |
| `npm run claude:down` | OpenCodex와 인증 프록시 종료 |

`npm run claude:okta*`는 같은 CLI 별칭입니다.

Claude Code LLM gateway 프로토콜: https://code.claude.com/docs/en/llm-gateway  
OpenCodex 연동: https://opencodex.me/guides/claude-code/

## 12. 모델, streaming, tool 확인

1. `npm run claude:doctor`가 `ok`인지 확인합니다.
2. Claude Code 모델 목록에 APIM catalog 모델이 보이는지 확인합니다.
3. Responses 모델과 Chat 모델로 짧은 prompt를 보냅니다.
4. streaming 응답이 끊기지 않는지 확인합니다.
5. Read 같은 tool 호출이 한 세션에서 이어지는지 확인합니다.

기본 모델은 catalog에서 Responses 모델 우선, 없으면 첫 Chat 모델입니다.
`LLMGW_CLAUDE_DEFAULT_MODEL`로 바꿀 수 있습니다.

Claude Code가 모델 이름을 몰라 200k로 가정한다는 경고가 나면, Terraform catalog에 실제
`context_window`를 넣은 뒤 `npm run claude:configure`와 `npm run claude:restart`를 실행합니다.
값을 추측하지 않습니다.

## 13. 장애 대응

어느 계층인지 먼저 나눕니다: 로컬 프로세스, Okta, APIM, Foundry.

| 증상 | 확인 | 조치 |
|---|---|---|
| `claude` 없음 / Node 20 미만 | `npm run claude:doctor` | CLI와 Node를 설치 |
| OpenCodex pin 불일치 | doctor `prerequisites` | 저장소에서 `npm ci` |
| port 충돌 | 10100 / 10101 | `LLMGW_OPENCODEX_PORT`, `LLMGW_AUTH_PROXY_PORT` 또는 점유 프로세스 종료 |
| stale proxy / 이전 게이트웨이 | doctor `auth_proxy` / `opencodex` `matches: false` | `npm run claude:restart` |
| 브라우저 로그인 반복 | token cache, `offline_access` | cache 삭제 후 `npm run claude` |
| `401` / `login_required` | 만료된 refresh, 잘못된 client | 대화형으로 다시 로그인. 요청 중 Device Flow는 열리지 않음 |
| `403` | `routed_models`, 모델 이름 | deployment name과 allowlist 확인 |
| `429` | quota, `user_tokens_per_minute` | `Retry-After`, Foundry quota |
| `5xx` | Foundry/APIM backend | 잠시 후 제한 재시도. prompt/token을 지원 요청에 넣지 않음 |
| discovery URL 거부 | URL에 `/realms/` 등 Okta가 아닌 경로 | Okta discovery와 client ID로 교체 |

지원 요청에는 시각, 모델, API(`responses`/`chat`), HTTP status, 응답 body만 넣습니다.
prompt, access token, refresh token은 첨부하지 않습니다.

## 14. 정리

```bash
npm run claude:down
```

OpenCodex와 인증 프록시는 Claude Code를 꺼도 재사용을 위해 남아 있습니다. 종료는 `down`이
필요합니다.

로컬 파일까지 지울 때:

- Windows: `%USERPROFILE%\.llmgw\opencodex-okta`, `%USERPROFILE%\.llmgw\okta-claude-token.json`
- macOS / Linux: `~/.llmgw/opencodex-okta`, `~/.llmgw/okta-claude-token.json`

APIM OIDC 설정을 바꾸려면 `oidc_provider`를 의도한 값으로 plan에서 확인한 뒤 apply합니다.

## 15. 설정 책임표

| 값 | 누가 | 어디에 | 비밀 | 필수 | 검증 |
|---|---|---|---|---|---|
| Azure subscription / tenant | Azure 관리자 | Azure | 아니요 | 필수 | `az account show` |
| `location` | Azure 관리자 | tfvars | 아니요 | 필수 | 모델 quota |
| `prefix`, `env`, `owner`, `cost_center` | Azure 관리자 | tfvars | 아니요 | 필수 | plan |
| `apim_sku` | Azure 관리자 | tfvars | 아니요 | 기본 `Premium_1` | plan |
| Foundry deployment / project ID | Azure 관리자 | tfvars | 아니요 | 모델 1개 이상 | `az cognitiveservices ...` |
| `opencode_api` | Azure 관리자 | tfvars | 아니요 | 모델별 | 실제 Responses/Chat 호출 |
| `routed_models` | Azure 관리자 | tfvars | 아니요 | 기본=전체 배포 | output `routed_models` |
| `context_window` / `tools` / `streaming` | Azure 관리자 | tfvars | 아니요 | 선택, 추측 금지 | `client_profile` |
| Okta discovery, issuer, audience | Okta 관리자 | Okta + tfvars | 아니요 | 필수 | discovery HTTP 200 |
| Okta Native client ID | Okta 관리자 | Okta + tfvars | public | 필수 | Device Flow |
| Okta scope / role claim | Okta 관리자 | Okta + tfvars | 아니요 | 필수 | token payload |
| `gateway_base_url` | 자동 | `client_profile` | 아니요 | 필수 | output |
| `LLMGW_CLIENT_PROFILE` | 고객 PC | 환경 변수 | 아니요 | 권장 | `npm run claude:doctor` |
| `LLMGW_CLAUDE_*_MODELS` | 고객 PC | 환경 변수 | 아니요 | profile 없을 때 | doctor |
| OpenCodex / proxy port | 고객 PC | 환경 변수 | 아니요 | 기본 10100/10101 | doctor, `/health` `/healthz` |
| Okta access/refresh token | 고객 PC | `okta-claude-token.json` | **예** | 런타임 | doctor `token_cache` (만료만) |
| APIM Managed Identity | Terraform | Azure RBAC | 클라우드 자격 증명 | 필수 | Foundry 호출 200 |

## 관련 문서

- [Configure Claude Code for Microsoft Foundry](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-claude-code)
- [Foundry model endpoints](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/endpoints)
- [APIM authenticate/authorize AI APIs](https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis)
- [APIM `validate-jwt`](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [APIM managed identity policy](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [Import Microsoft Foundry API](https://learn.microsoft.com/azure/api-management/azure-ai-foundry-api)
- [Okta Device Authorization Grant](https://developer.okta.com/docs/guides/device-authorization-grant/main/)
- [Claude Code LLM gateway](https://code.claude.com/docs/en/llm-gateway)
- [OpenCodex Claude Code](https://opencodex.me/guides/claude-code/)
- [운영 문서](operations.md)
- [Okta 관리자 가이드](okta-admin-guide.md)
