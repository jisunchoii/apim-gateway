# OpenCode에서 Claude Gateway 사용

이 문서는 Korea Central Claude Standard v2 APIM을 OpenCode의 custom Anthropic provider로
연결하는 방법을 설명합니다. OpenCode는 `@ai-sdk/anthropic` provider를 사용하고, APIM의
Anthropic Messages API인 `POST /v1/messages`를 호출합니다.

## 준비 값

운영자에게 다음 값을 받습니다.

| 항목 | 사용자 OIDC | 서비스 계정 |
|---|---|---|
| Gateway URL | `claude_gateway_base_url` | `claude_service_gateway_base_url` |
| 인증 정보 | Keycloak discovery URL, client ID, scope | Service Claude Gateway API 범위의 APIM subscription key |
| 모델 | 허용된 `system.ai.claude-*` 모델 이름 | 허용된 `system.ai.claude-*` 모델 이름 |

Terraform state에 접근할 수 있는 운영자는 다음 output으로 URL과 모델을 확인합니다.

```powershell
terraform -chdir=infra\environments\claude-standard-v2 output -raw claude_gateway_base_url
terraform -chdir=infra\environments\claude-standard-v2 output -raw claude_service_gateway_base_url
terraform -chdir=infra\environments\claude-standard-v2 output -json claude_gateway_models
```

Terraform output의 URL은 `/anthropic` 또는 `/service/anthropic`에서 끝납니다. 저장소의 OIDC
hook은 사용자 URL에 `/v1`을 자동으로 붙입니다. 서비스 계정처럼 provider를 직접 설정할 때는
URL 뒤에 `/v1`을 붙입니다. `@ai-sdk/anthropic`이 여기에 `/messages`를 추가하여 APIM의 실제
operation을 호출합니다.

## 1. 사용자 OIDC 연결

저장소의 `opencode.json`은 Claude Sonnet을 기본 모델, Haiku를 small model로 설정하고 Keycloak
hook을 로드합니다.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llmgw-claude/system.ai.claude-sonnet-5",
  "small_model": "llmgw-claude/system.ai.claude-haiku-4-5",
  "plugin": ["./scripts/keycloak/opencode-keycloak-hook.js"]
}
```

Hook은 Claude Terraform의 `claude_gateway_base_url`과 `claude_gateway_models` output을 읽어
`llmgw-claude` Anthropic provider를 등록합니다. 각 요청 직전에 Keycloak credential에서 token을
가져오므로 access token이 만료되면 저장된 refresh token으로 자동 갱신합니다.

저장소와 local Terraform state가 있으면 별도 설정 없이 실행합니다.

```powershell
opencode
```

단발성 연결 확인:

```powershell
opencode run --model "llmgw-claude/system.ai.claude-sonnet-5" "Reply with exactly: OK"
```

Terraform state가 없는 PC에서는 운영자가 제공한 URL, 모델 목록과 Keycloak 값을 설정합니다.
`LLMGW_CLAUDE_BASE_URL`은 `/v1`을 포함하거나 생략할 수 있습니다.

```powershell
$env:LLMGW_CLAUDE_BASE_URL = "https://<apim-name>.azure-api.net/anthropic"
$env:LLMGW_OPENCODE_CLAUDE_MODELS = "system.ai.claude-opus-5,system.ai.claude-sonnet-5,system.ai.claude-haiku-4-5,system.ai.claude-fable-5"
$env:LLMGW_OPENCODE_CLAUDE_DEFAULT_MODEL = "system.ai.claude-sonnet-5"
$env:LLMGW_OPENCODE_CLAUDE_SMALL_MODEL = "system.ai.claude-haiku-4-5"
$env:LLMGW_OIDC_DISCOVERY_URL = "https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration"
$env:LLMGW_OIDC_CLIENT_ID = "llm-gateway-cli"
$env:LLMGW_OIDC_SCOPE = "openid llm-gateway"

opencode
```

최초 요청 시 브라우저에서 Device Flow 로그인을 승인합니다. 이후 access/refresh token은 사용자
프로필의 `~/.llmgw/keycloak-token.json`에 제한된 권한으로 저장됩니다.

## 2. 서비스 계정 연결

서비스 계정은 Keycloak token 대신 `Service Claude Gateway` API 범위의 APIM subscription key를
`Ocp-Apim-Subscription-Key` header로 전송합니다.

`opencode.claude-service.json`을 만듭니다.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llmgw-claude/system.ai.claude-sonnet-5",
  "small_model": "llmgw-claude/system.ai.claude-haiku-4-5",
  "provider": {
    "llmgw-claude": {
      "npm": "@ai-sdk/anthropic",
      "name": "LLM Gateway Claude Service",
      "options": {
        "baseURL": "{env:LLMGW_CLAUDE_API_BASE_URL}",
        "apiKey": "unused",
        "headers": {
          "Ocp-Apim-Subscription-Key": "{env:LLMGW_SUBSCRIPTION_KEY}"
        },
        "timeout": 300000
      },
      "models": {
        "system.ai.claude-opus-5": {
          "name": "Claude Opus 5",
          "tool_call": true
        },
        "system.ai.claude-sonnet-5": {
          "name": "Claude Sonnet 5",
          "tool_call": true
        },
        "system.ai.claude-haiku-4-5": {
          "name": "Claude Haiku 4.5",
          "tool_call": true
        },
        "system.ai.claude-fable-5": {
          "name": "Claude Fable 5",
          "tool_call": true
        }
      }
    }
  }
}
```

`apiKey`의 `unused` 값은 Anthropic provider 초기화에만 사용됩니다. Gateway policy가
`x-api-key`를 제거하며, 실제 APIM 인증은 subscription header로 수행됩니다.

```powershell
$gatewayBaseUrl = terraform -chdir=infra\environments\claude-standard-v2 output -raw claude_service_gateway_base_url
$env:LLMGW_CLAUDE_API_BASE_URL = "$($gatewayBaseUrl.TrimEnd('/'))/v1"
$env:LLMGW_SUBSCRIPTION_KEY = "<service-account-subscription-key>"
$env:OPENCODE_CONFIG = "$PWD\opencode.claude-service.json"

opencode run --pure --model "llmgw-claude/system.ai.claude-sonnet-5" "Reply with exactly: OK"
```

Terraform state가 없는 PC에서는 URL을 직접 설정합니다.

```powershell
$env:LLMGW_CLAUDE_API_BASE_URL = "https://<apim-name>.azure-api.net/service/anthropic/v1"
```

## Linux와 macOS

같은 설정 파일을 사용하고 환경 변수만 shell 문법에 맞게 설정합니다.

```bash
gateway_base_url="$(
  terraform -chdir=infra/environments/claude-standard-v2 \
    output -raw claude_service_gateway_base_url
)"
export LLMGW_CLAUDE_API_BASE_URL="${gateway_base_url%/}/v1"
export LLMGW_SUBSCRIPTION_KEY="<service-account-subscription-key>"
export OPENCODE_CONFIG="$PWD/opencode.claude-service.json"

opencode run --pure \
  --model "llmgw-claude/system.ai.claude-sonnet-5" \
  "Reply with exactly: OK"
```

## 오류 대응

| 상태 또는 증상 | 확인할 항목 |
|---|---|
| `401` | 사용자 token 만료 여부 또는 서비스 subscription key 값과 API scope를 확인합니다. |
| `403` | 모델 이름이 현재 Gateway의 허용된 `system.ai.claude-*` 목록과 일치하는지 확인합니다. |
| `404` | OIDC의 `LLMGW_CLAUDE_BASE_URL` 또는 서비스의 `LLMGW_CLAUDE_API_BASE_URL` 경로를 확인합니다. |
| `400` | 모델 이름, request 형식과 Gateway 응답 body를 확인합니다. |
| 모델이 목록에 없음 | OIDC는 Terraform output 또는 `LLMGW_OPENCODE_CLAUDE_MODELS`, 서비스는 `opencode.claude-service.json`의 `models`를 확인합니다. |

OpenCode가 사용하는 API는 `POST /v1/messages`입니다. 현재 Gateway는
`POST /v1/messages/count_tokens`를 제공하지 않습니다.

## 보안

- access token과 subscription key를 JSON 파일, source, `.env` 또는 명령 기록에 저장하지 않습니다.
- 서비스마다 API-scoped subscription을 별도로 발급하고 공유하지 않습니다.
- APIM의 built-in all-access subscription key를 일반 OpenCode 연결에 사용하지 않습니다.
- 키는 정기적으로 교체하고 두 개의 APIM key를 이용해 중단 없이 rotation합니다.

## 공식 문서

- [OpenCode provider 설정](https://opencode.ai/docs/providers/)
- [OpenCode config 파일과 우선순위](https://opencode.ai/docs/config/)
- [AI SDK Anthropic provider와 custom baseURL](https://ai-sdk.dev/providers/ai-sdk-providers/anthropic)
- [Azure API Management subscriptions](https://learn.microsoft.com/azure/api-management/api-management-subscriptions)
- [Azure API Management subscription 생성](https://learn.microsoft.com/azure/api-management/api-management-howto-create-subscriptions)
