# LLM Gateway 사용 안내

이 Gateway는 회사에서 승인한 Microsoft Foundry 모델을 OpenAI 호환 API로 제공합니다. 최종 사용자는
Keycloak Device Authorization Grant로 로그인하고 Azure API Management(APIM)에 bearer token을
보냅니다. 서비스 계정은 별도 API에 APIM subscription key를 보냅니다. 두 API 모두 APIM Managed
Identity와 Azure RBAC로 Foundry backend를 호출합니다.

## 접속 정보

Gateway base URL은 운영자가 안내하며, 운영자는 Terraform output `gateway_base_url`에서
확인합니다. 형식은 다음과 같습니다.

```text
https://<apim-name>.azure-api.net/openai/v1
```

서비스 계정용 base URL은 Terraform output `service_gateway_base_url`에서 확인합니다.

```text
https://<apim-name>.azure-api.net/service/openai/v1
```

Keycloak 연결에는 다음 값이 필요합니다.

| 항목 | 예시 |
|---|---|
| Discovery URL | `https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration` |
| Public client ID | `llm-gateway-cli` |
| Requested scope | `openid llm-gateway` |
| API audience | `llm-gateway-api` |
| Role claim | `llm_gateway_roles` |
| Required role | `invoke` |
| User label claim | `llm_gateway_user` |

Keycloak realm에 로그인 가능하고 `llm-gateway-api/invoke` client role이 할당된 계정이 있어야
합니다. 고객 PC에 client secret을 배포하지 않으며, 최초 로그인 시 브라우저에서 user code를
승인합니다.

## 빠른 연결 확인

저장소를 받은 뒤 운영자가 안내한 Keycloak 값을 환경 변수로 설정합니다.

```bash
export LLMGW_BASE_URL="https://<apim-name>.azure-api.net/openai/v1"
export LLMGW_OIDC_DISCOVERY_URL="https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration"
export LLMGW_OIDC_CLIENT_ID="llm-gateway-cli"
export LLMGW_OIDC_SCOPE="openid llm-gateway"
export LLMGW_MODEL="<model-name>"

TOKEN="$(node ./scripts/keycloak/keycloak-token.js)"
```

최초 실행 시 터미널에 verification URL과 user code가 표시됩니다. 브라우저에서 로그인을 완료하면
helper가 access token만 표준 출력으로 반환합니다. 이후에는 사용자 프로필의 제한된 캐시에서
refresh token을 읽어 access token을 자동 갱신합니다.

Responses API를 확인합니다.

```bash
curl --silent --show-error \
  --request POST \
  --url "$LLMGW_BASE_URL/responses" \
  --header "Authorization: Bearer $TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"model\":\"$LLMGW_MODEL\",\"input\":\"Reply with exactly: OK\",\"max_output_tokens\":32}"
```

Chat Completions API를 확인합니다.

```bash
curl --silent --show-error \
  --request POST \
  --url "$LLMGW_BASE_URL/chat/completions" \
  --header "Authorization: Bearer $TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"model\":\"$LLMGW_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_completion_tokens\":32}"
```

### 서비스 계정 연결

서비스 계정은 `Service Model Gateway` API 범위로 발급된 고유 subscription key를 사용합니다.
Keycloak token은 보내지 않으며, 키는 `Ocp-Apim-Subscription-Key` header로 전달합니다.
Terraform 배포 환경에서는 주소를 직접 조합하지 않고 `service_gateway_base_url` output을 사용합니다.
Terraform state에 접근할 수 없는 서비스 운영자는 APIM 운영자에게 이 output 값을 전달받습니다.

```bash
export LLMGW_SERVICE_BASE_URL="$(terraform -chdir=infra output -raw service_gateway_base_url)"
export LLMGW_SUBSCRIPTION_KEY="<service-account-subscription-key>"

curl --silent --show-error \
  --request POST \
  --url "$LLMGW_SERVICE_BASE_URL/responses" \
  --header "Ocp-Apim-Subscription-Key: $LLMGW_SUBSCRIPTION_KEY" \
  --header "Content-Type: application/json" \
  --data "{\"model\":\"$LLMGW_MODEL\",\"input\":\"Reply with exactly: OK\",\"max_output_tokens\":32}"
```

서비스마다 subscription을 하나씩 발급하고 공유하지 않습니다. CI에서는 GitHub Actions의
repository 또는 environment secret에 `LLMGW_SUBSCRIPTION_KEY`로 저장하고, Azure 워크로드에서는
[Azure Key Vault](https://learn.microsoft.com/azure/key-vault/general/overview)에 저장한 뒤
실행 시 환경변수로 주입합니다. 로컬에서도 회사가 승인한 비밀 저장소에서 환경변수로 주입하며,
키를 source, `.env`, 클라이언트 설정 파일, 명령 기록에 직접 저장하지 않습니다.

## 지원 API

OpenAI 호환 `gateway_base_url`에는 이미 `/openai/v1`이 포함되어 있습니다.

| Method | Suffix | 용도 |
|---|---|---|
| `POST` | `/responses` | OpenAI Responses 형식입니다. Codex CLI와 GPT 계열에 권장합니다. |
| `POST` | `/chat/completions` | OpenAI Chat Completions 형식입니다. `messages` 기반 클라이언트와 OpenCode Foundry 모델에 사용합니다. |

Claude Code는 별도 Korea Central Standard v2 stack의 `claude_gateway_base_url`을 사용합니다.
기존 Classic APIM은 AOAI/Fireworks의 OpenAI 호환 API만 제공합니다.

다음 API는 현재 제공하지 않습니다.

- `GET /models`
- `POST /responses/compact`
- Anthropic `POST /v1/messages/count_tokens` (Claude Code가 inference endpoint 기반 계산으로 fallback)
- Embeddings, Images, Audio API

미지원 경로는 일반적으로 `404`를 반환합니다.

### 공통 요청 규칙

최종 사용자 API는 Keycloak bearer token, 서비스 계정 API는
`Ocp-Apim-Subscription-Key` header가 필요합니다. 두 API 모두
`Content-Type: application/json`과 정확한 `model` 이름을 사용합니다. APIM은 인증 후
`routed_models`에 해당하는 Foundry backend를 선택하고 Managed Identity로 요청을 전달합니다.

`POST /chat/completions`는 legacy `max_tokens`를 `max_completion_tokens`로 변환하고 streaming
사용량 집계를 활성화합니다. `POST /responses`는 Responses 형식을 유지하며 backend가 받지 않는
Chat 전용 `stream_options`를 제거합니다. 또한 OpenCode가 role 기반 `input` item의 `type`을
누락하거나 빈 문자열로 보내면 Foundry Responses 형식에 맞게 `type: "message"`를 채웁니다.

## Coding agent 설정

### Claude Code

Claude Code는 `infra/environments/claude-standard-v2/`로 배포한 별도 APIM의 Anthropic
Messages API를 사용합니다. `apiKeyHelper`는 기존 Keycloak Device Flow credential을 사용해
access token을 발급하고 refresh token으로 자동 갱신합니다. Standard v2 APIM은 Keycloak JWT를
검증한 뒤 Authorization header를 관리 ID token으로 교체하여 Azure Databricks Unity AI Gateway에
전달합니다.

Linux 사용자 설정 `~/.claude/settings.json` 예시입니다. `apiKeyHelper` 경로는 저장소의 실제
절대 경로로 변경합니다.

```json
{
  "apiKeyHelper": "node /home/<linux-user>/src/apim-gateway/scripts/keycloak/keycloak-token.js --open-browser",
  "env": {
    "LLMGW_OIDC_DISCOVERY_URL": "https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration",
    "LLMGW_OIDC_CLIENT_ID": "llm-gateway-cli",
    "LLMGW_OIDC_SCOPE": "openid llm-gateway",
    "ANTHROPIC_BASE_URL": "https://<claude-standard-v2-apim>.azure-api.net/anthropic",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "system.ai.claude-opus-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "system.ai.claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "system.ai.claude-haiku-4-5",
    "ENABLE_PROMPT_CACHING_1H": "1",
    "ENABLE_TOOL_SEARCH": "1"
  },
  "permissions": {
    "deny": [
      "WebSearch"
    ],
    "allow": [
      "WebFetch"
    ]
  }
}
```

Azure Databricks Foundation Model API는 Anthropic native `WebSearch`를 지원하지 않으므로 위와
같이 비활성화하여 반복되는 `400` 응답을 방지하는 구성을 권장합니다. `WebFetch`는 알고 있는 URL의
내용을 가져올 수 있지만 검색 엔진을 완전히 대체하지는 않습니다. 일반적인 웹 검색이 필요하면
[Azure Databricks Web Search 공식 가이드](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/web-search)에
따라 You.com 같은 Web Search MCP server를 연결합니다. Claude Code의 도구 허용·차단 방식은
[Claude Code permissions 공식 문서](https://code.claude.com/docs/en/permissions)를 참고합니다.

설정 파일을 현재 사용자만 읽을 수 있도록 제한한 뒤 Claude Code를 실행합니다.

```bash
mkdir -p ~/.claude
chmod 700 ~/.claude
chmod 600 ~/.claude/settings.json
claude
```

저장소와 local Terraform state가 있는 Linux 환경에서는 다음 명령으로 Gateway를 직접 확인할 수
있습니다. Terraform state가 없는 사용자 PC에서는 `CLAUDE_GATEWAY_BASE_URL`을 운영자가 안내한
URL로 설정합니다.

```bash
cd /home/<linux-user>/src/apim-gateway

export CLAUDE_GATEWAY_BASE_URL="$(
  terraform -chdir=infra/environments/claude-standard-v2 \
    output -raw claude_gateway_base_url
)"
export LLMGW_OIDC_DISCOVERY_URL="https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration"
export LLMGW_OIDC_CLIENT_ID="llm-gateway-cli"
export LLMGW_OIDC_SCOPE="openid llm-gateway"

TOKEN="$(node ./scripts/keycloak/keycloak-token.js --open-browser)"

curl --silent --show-error \
  --request POST \
  --url "$CLAUDE_GATEWAY_BASE_URL/v1/messages" \
  --header "Authorization: Bearer $TOKEN" \
  --header "anthropic-version: 2023-06-01" \
  --header "Content-Type: application/json" \
  --data '{"model":"system.ai.claude-sonnet-5","max_tokens":64,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}'
```

SSE streaming은 `curl --no-buffer`와 `"stream":true`로 확인합니다.

```bash
curl --no-buffer --silent --show-error \
  --request POST \
  --url "$CLAUDE_GATEWAY_BASE_URL/v1/messages" \
  --header "Authorization: Bearer $TOKEN" \
  --header "anthropic-version: 2023-06-01" \
  --header "Content-Type: application/json" \
  --data '{"model":"system.ai.claude-sonnet-5","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}'
```

`apiKeyHelper` 결과는 Claude Code가 `Authorization`과 `x-api-key`에 함께 넣지만 APIM은
Authorization의 Keycloak JWT만 검증하고 `x-api-key`는 backend 전달 전에 제거합니다.
`ANTHROPIC_MODEL`은 설정하지 않아야 `/model opus`, `/model sonnet`, `/model haiku`가 위 family
기본값으로 각각 전환됩니다. Fable은 `claude --model system.ai.claude-fable-5`처럼 정확한
모델명을 지정해 사용합니다. Fable의 데이터 처리 조건은
[Databricks Claude 고객 설정 가이드](docs/databricks-claude-apim-guide.md#3-claude-model-권한)를
확인합니다.

### OpenCode

#### 사용자 OIDC

`opencode.json`은 `scripts/keycloak/opencode-keycloak-hook.js`를 로드합니다. Hook은 최초에만
Device Flow로 로그인하고 access/refresh token을 사용자 프로필의 `~/.llmgw/keycloak-token.json`에
저장한 뒤 만료 전에 자동 갱신합니다. 캐시 경로는 `LLMGW_OIDC_CACHE_PATH`로 변경할 수 있습니다.
로그인이 필요하면 기본 브라우저에서 verification URL을 자동으로 열며, 터미널에도 URL과 user
code를 계속 표시합니다. 브라우저 자동 실행이 불가능한 환경에서는
`LLMGW_OIDC_OPEN_BROWSER=false`로 비활성화할 수 있습니다.
모델 목록과 기본 모델은 main Terraform의 `opencode_model_config` output에서 읽으므로
`routed_models`와 별도로 하드코딩하지 않습니다.

```bash
export LLMGW_BASE_URL="https://<apim-name>.azure-api.net/openai/v1"
export LLMGW_OIDC_DISCOVERY_URL="https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration"
export LLMGW_OIDC_CLIENT_ID="llm-gateway-cli"
export LLMGW_OIDC_SCOPE="openid llm-gateway"

opencode
```

Terraform state에 접근할 수 없는 고객 PC에서는 운영자가 제공한 목록을 환경 변수로 설정합니다.
값은 쉼표 구분 문자열 또는 JSON 배열입니다.

```bash
export LLMGW_OPENCODE_RESPONSES_MODELS="gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-luna"
export LLMGW_OPENCODE_CHAT_MODELS="FW-GLM-5.2,FW-Kimi-K3"
export LLMGW_OPENCODE_DEFAULT_MODEL="gpt-5.6-sol"
export LLMGW_OPENCODE_SMALL_MODEL="gpt-5.6-luna"
```

단발성 호출은 `openai/<model>` 또는 `foundry/<model>` 형식을 사용합니다. provider는 모델을
어디서 생성했는지가 아니라 각 deployment의 `opencode_api` 값으로 결정됩니다.
`responses`는 `openai`, `chat`은 `foundry` provider에 배치됩니다.
Responses 모델에는 tool calling, system message, high reasoning, reasoning summary,
low text verbosity, encrypted reasoning content와 Responses server-side state 저장이 기본
적용됩니다. 저장을 활성화하면 OpenCode의 tool 후속 요청이 reasoning 객체를 다시 직렬화하지
않고 Foundry `item_reference`를 사용하므로 agent loop가 유지됩니다. `opencode.json`의 동일
모델 설정은 Hook이 보존하며 기본값보다 우선합니다.

```bash
opencode run --model openai/gpt-5.6-sol "Reply with exactly: OK"
opencode run --model foundry/FW-GLM-5.2 "Reply with exactly: OK"
```

Responses stream과 호환되지 않는 모델은 `opencode_api = "chat"`으로 설정합니다. GPT 계열을
Chat으로 호출하도록 설정한 경우 Hook은 지원되지 않는 Responses 전용 reasoning 옵션을 제거합니다.

#### 서비스 계정

서비스 계정은 Keycloak hook을 사용하지 않습니다. 고객 프로젝트의 `opencode.json`에 서비스용
provider를 직접 설정하고, 운영자가 안내한 Responses 모델과 Chat 모델만 등록합니다.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llmgw-responses/<responses-model>",
  "small_model": "llmgw-responses/<responses-model>",
  "provider": {
    "llmgw-responses": {
      "npm": "@ai-sdk/openai",
      "name": "LLM Gateway Responses",
      "options": {
        "baseURL": "https://<apim-name>.azure-api.net/service/openai/v1",
        "apiKey": "unused",
        "headers": {
          "Ocp-Apim-Subscription-Key": "{env:LLMGW_SUBSCRIPTION_KEY}"
        },
        "timeout": 300000
      },
      "models": {
        "<responses-model>": {
          "name": "<responses-model>",
          "tool_call": true,
          "options": {
            "systemMessageMode": "system",
            "reasoningEffort": "high",
            "reasoningSummary": "auto",
            "textVerbosity": "low",
            "store": true,
            "include": ["reasoning.encrypted_content"]
          }
        }
      }
    },
    "llmgw-chat": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LLM Gateway Chat",
      "options": {
        "baseURL": "https://<apim-name>.azure-api.net/service/openai/v1",
        "apiKey": "unused",
        "headers": {
          "Ocp-Apim-Subscription-Key": "{env:LLMGW_SUBSCRIPTION_KEY}"
        },
        "timeout": 300000
      },
      "models": {
        "<chat-model>": {
          "name": "<chat-model>"
        }
      }
    }
  }
}
```

`apiKey`의 `unused` 값은 OpenCode provider SDK 초기화용이며 인증 정보가 아닙니다. 실제 인증은
환경 변수에서 읽은 APIM subscription header로 수행됩니다.

`<responses-model>`과 `<chat-model>`은 운영자가 안내한 실제 모델 이름으로 모두 교체합니다.
구독 키와 실행할 모델을 환경 변수로 설정한 뒤 provider를 선택합니다.

```bash
export LLMGW_SUBSCRIPTION_KEY="<service-account-subscription-key>"
export LLMGW_RESPONSES_MODEL="<responses-model>"
export LLMGW_CHAT_MODEL="<chat-model>"

opencode --model "llmgw-responses/$LLMGW_RESPONSES_MODEL"
opencode run --model "llmgw-chat/$LLMGW_CHAT_MODEL" "Reply with exactly: OK"
```

현재 저장소처럼 project `opencode.json`이 OIDC plugin을 로드하는 환경에서 서비스 계정 설정을
별도 파일로 사용하는 경우에는 `OPENCODE_CONFIG`로 파일을 지정하고 `--pure`를 함께 사용하여
OIDC plugin을 비활성화합니다.

```bash
export OPENCODE_CONFIG="/path/to/service-opencode.json"
opencode run --pure --model "llmgw-responses/$LLMGW_RESPONSES_MODEL" "Review the current change"
```

### Codex CLI

#### 사용자 OIDC

Codex에는 static API key 대신 Keycloak token helper를 command credential로 연결합니다. 아래
경로는 저장소의 실제 절대 경로로 변경합니다.

```toml
# ~/.codex/config.toml
model_provider = "llmgw"
model = "<responses-model>"

[model_providers.llmgw]
name = "LLM Gateway"
base_url = "https://<apim-name>.azure-api.net/openai/v1"
wire_api = "responses"

[model_providers.llmgw.auth]
command = "node"
args = ["/absolute/path/to/apim-gateway/scripts/keycloak/keycloak-token.js", "--open-browser"]
timeout_ms = 600000
refresh_interval_ms = 240000
```

Codex는 `auth.command`의 표준 오류를 프로세스가 끝날 때까지 캡처하므로 Device Flow URL을
터미널에 실시간으로 표시하지 않습니다. `--open-browser`를 사용하면 최초 로그인이나 refresh
실패로 Device Flow가 필요할 때 helper가 인증 URL을 기본 브라우저로 직접 엽니다. Codex는 로그인을
기다리며, 브라우저에서 승인을 완료하면 요청을 이어서 실행합니다.

`keycloak-token.js`는 안내 문구와 오류를 표준 오류에, access token만 표준 출력에 기록합니다.
refresh token은 OpenCode hook과 같은 사용자 프로필의 `~/.llmgw/keycloak-token.json`에 저장되며
소스 코드나 `.env`에는 저장하지 않습니다. 유효한 캐시 또는 refresh token이 있으면 브라우저를
열지 않고 자동으로 access token을 반환합니다.

브라우저가 자동으로 열리지 않으면 별도 터미널에서 helper를 직접 실행해 로그인한 뒤 Codex를
다시 시작합니다. 이미 Device Flow에서 대기 중인 Codex 프로세스도 종료 후 다시 실행해야 변경된
`auth.command` 인수가 적용됩니다.

```powershell
node C:\absolute\path\to\apim-gateway\scripts\keycloak\keycloak-token.js --open-browser 1>$null
codex --profile llmgw -m gpt-5.6-sol
```

#### 서비스 계정

Codex는 Responses API만 사용합니다. 사용자 OIDC 설정과 함께 사용하는 PC에서는
`~/.codex/service-account.config.toml`을 별도 profile로 생성합니다.

```toml
model_provider = "llmgw_service"
model = "<responses-model>"

[model_providers.llmgw_service]
name = "LLM Gateway Service"
base_url = "https://<apim-name>.azure-api.net/service/openai/v1"
wire_api = "responses"
requires_openai_auth = false

[model_providers.llmgw_service.env_http_headers]
"Ocp-Apim-Subscription-Key" = "LLMGW_SUBSCRIPTION_KEY"

[shell_environment_policy]
inherit = "core"
ignore_default_excludes = false

[shell_environment_policy.filters]
"LLMGW_SUBSCRIPTION_KEY" = "exclude"
```

구독 키를 환경 변수로 설정하고 service profile을 선택합니다. `OPENAI_API_KEY`나 Keycloak
token은 설정하지 않습니다.

```bash
export LLMGW_SUBSCRIPTION_KEY="<service-account-subscription-key>"

codex --profile service-account
codex exec --profile service-account "Review the current change"
```

Node helper는 Node.js 20 이상을 지원합니다. 커밋 대상 helper의 구문 검사는 `npm run check`로
실행합니다.

## 오류 대응

| 상태 | 의미 | 고객 조치 |
|---|---|---|
| `400` | 잘못된 JSON 또는 `model` 누락 | request body와 모델 이름을 확인합니다. |
| `401` | 사용자 token 또는 서비스 subscription key 누락·오류 | 사용자는 token helper, 서비스는 subscription key 설정을 확인합니다. |
| `403` | Gateway에 라우팅되지 않은 모델 | 현재 지원 모델을 운영자에게 확인합니다. |
| `404` | 등록되지 않은 API 경로 | `/responses` 또는 `/chat/completions`를 사용합니다. |
| `429` | 사용자 제한 또는 backend TPM/RPM 제한 | `Retry-After`를 따르고 exponential backoff를 적용합니다. |
| `500` | backend 연결 또는 처리 실패 | 무제한 재시도를 피하고 잠시 후 제한적으로 재시도합니다. |
| `503` | circuit breaker 또는 일시적 backend 불가 | `Retry-After` 후 제한적으로 재시도합니다. |

문제를 신고할 때는 발생 시각과 시간대, 모델, API suffix, HTTP status와 응답 body를 전달합니다.
Prompt, access token, refresh token과 고객 데이터는 지원 요청에 첨부하지 않습니다.

## 보안과 사용량 기록

- 고객 인증은 Keycloak OIDC Device Authorization Grant로 수행합니다.
- 서비스 계정 인증은 별도 API의 APIM API-scoped subscription으로 수행합니다.
- APIM에서 Foundry로의 인증은 Managed Identity와 Azure RBAC를 사용합니다.
- APIM은 Keycloak의 `iss:sub`를 SHA-256으로 해시하여 사용자별 사용량을 집계합니다.
- Workbook 표시용 Keycloak username은 `userLabel`로 Azure Monitor trace에 저장됩니다.
- Classic Workbook은 GPT cached input token과 discounted input 비용을 Application Insights metric으로 집계합니다.
- Gateway 진단 로그에는 prompt와 model output을 저장하지 않습니다.
- Keycloak client는 public client이며 client secret을 사용하지 않습니다.

Terraform 배포, 모델 관리, Workbook과 로그 쿼리는
[운영 문서](docs/operations.md)를 참고합니다.

## 관련 문서

- [Korea Central Claude Standard v2 APIM 구축 가이드](docs/claude-standard-v2-deployment.md)
- [Azure Databricks Claude 고객 설정 가이드](docs/databricks-claude-apim-guide.md)
- [Keycloak Device Authorization Grant](https://www.keycloak.org/docs/latest/server_admin/#_oid4vc_device_authorization_grant)
- [Azure API Management validate-jwt 정책](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [Azure API Management subscriptions](https://learn.microsoft.com/azure/api-management/api-management-subscriptions)
- [APIM Managed Identity 인증 정책](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [Azure OpenAI Responses API](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/responses)
- [Azure OpenAI Chat Completions](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/chatgpt)
- [Codex custom model providers](https://developers.openai.com/codex/config-advanced/#custom-model-providers)
- [OpenCode provider 설정](https://opencode.ai/docs/providers/)
