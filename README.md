# LLM Gateway 사용 안내

이 Gateway는 회사에서 승인한 Microsoft Foundry 모델을 OpenAI 호환 API로 제공합니다. 고객은
Keycloak Device Authorization Grant로 로그인하고 Azure API Management(APIM)에 bearer token을
보냅니다. APIM은 Managed Identity와 Azure RBAC로 Foundry backend를 호출합니다. API key와 APIM
subscription key는 사용하지 않습니다.

## 접속 정보

Gateway base URL은 운영자가 안내하며, 운영자는 Terraform output `gateway_base_url`에서
확인합니다. 형식은 다음과 같습니다.

```text
https://<apim-name>.azure-api.net/openai/v1
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

## 지원 API

Gateway base URL에는 이미 `/openai/v1`이 포함되어 있습니다.

| Method | Suffix | 용도 |
|---|---|---|
| `POST` | `/responses` | OpenAI Responses 형식입니다. Codex CLI와 GPT 계열에 권장합니다. |
| `POST` | `/chat/completions` | OpenAI Chat Completions 형식입니다. `messages` 기반 클라이언트와 OpenCode Foundry 모델에 사용합니다. |

다음 API는 현재 제공하지 않습니다.

- `GET /models`
- `POST /responses/compact`
- Anthropic `POST /v1/messages`
- Embeddings, Images, Audio API

미지원 경로는 일반적으로 `404`를 반환합니다.

### 공통 요청 규칙

두 API 모두 bearer token, `Content-Type: application/json`, 정확한 `model` 이름이 필요합니다.
APIM은 token의 서명, issuer, audience와 `scope=llm-gateway`를 검증한 뒤 `routed_models`에
해당하는 Foundry backend를 선택하고 Managed Identity로 요청을 전달합니다.

`POST /chat/completions`는 legacy `max_tokens`를 `max_completion_tokens`로 변환하고 streaming
사용량 집계를 활성화합니다. `POST /responses`는 Responses 형식을 유지하며 backend가 받지 않는
Chat 전용 `stream_options`를 제거합니다.

## Coding agent 설정

### OpenCode

`opencode.json`은 `scripts/keycloak/opencode-keycloak-hook.js`를 로드합니다. Hook은 최초에만
Device Flow로 로그인하고 access/refresh token을 사용자 프로필의 `~/.llmgw/keycloak-token.json`에
저장한 뒤 만료 전에 자동 갱신합니다. 캐시 경로는 `LLMGW_OIDC_CACHE_PATH`로 변경할 수 있습니다.
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

```bash
opencode run --model openai/gpt-5.6-sol "Reply with exactly: OK"
opencode run --model foundry/FW-GLM-5.2 "Reply with exactly: OK"
```

Responses stream과 호환되지 않는 모델은 `opencode_api = "chat"`으로 설정합니다. GPT 계열을
Chat으로 호출하도록 설정한 경우 Hook은 지원되지 않는 Responses 전용 reasoning 옵션을 제거합니다.

### Codex CLI

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
args = ["/absolute/path/to/apim-gateway/scripts/keycloak/keycloak-token.js"]
refresh_interval_ms = 240000
```

`keycloak-token.js`는 안내 문구를 표준 오류에, access token만 표준 출력에 기록합니다. refresh
token은 OpenCode hook과 같은 사용자 프로필의 `~/.llmgw/keycloak-token.json`에 저장되며 소스 코드나
`.env`에는 저장하지 않습니다.

Node helper는 Node.js 20 이상을 지원합니다. 커밋 대상 helper의 구문 검사는 `npm run check`로
실행합니다. 로컬 테스트 파일과 smoke script는 저장소 배포물에 포함하지 않습니다.

## 오류 대응

| 상태 | 의미 | 고객 조치 |
|---|---|---|
| `400` | 잘못된 JSON 또는 `model` 누락 | request body와 모델 이름을 확인합니다. |
| `401` | token 누락·만료, 잘못된 issuer·audience·scope | token helper를 다시 실행하고 Keycloak 설정을 확인합니다. |
| `403` | Gateway에 라우팅되지 않은 모델 | 현재 지원 모델을 운영자에게 확인합니다. |
| `404` | 등록되지 않은 API 경로 | `/responses` 또는 `/chat/completions`를 사용합니다. |
| `429` | 사용자 제한 또는 backend TPM/RPM 제한 | `Retry-After`를 따르고 exponential backoff를 적용합니다. |
| `500` | backend 연결 또는 처리 실패 | 무제한 재시도를 피하고 잠시 후 제한적으로 재시도합니다. |
| `503` | circuit breaker 또는 일시적 backend 불가 | `Retry-After` 후 제한적으로 재시도합니다. |

문제를 신고할 때는 발생 시각과 시간대, 모델, API suffix, HTTP status와 응답 body를 전달합니다.
Prompt, access token, refresh token과 고객 데이터는 지원 요청에 첨부하지 않습니다.

## 보안과 사용량 기록

- 고객 인증은 Keycloak OIDC Device Authorization Grant로 수행합니다.
- APIM에서 Foundry로의 인증은 Managed Identity와 Azure RBAC를 사용합니다.
- APIM은 Keycloak의 `iss:sub`를 SHA-256으로 해시하여 사용자별 사용량을 집계합니다.
- Workbook 표시용 Keycloak username은 `userLabel`로 Azure Monitor trace에 저장됩니다.
- Gateway 진단 로그에는 prompt와 model output을 저장하지 않습니다.
- Keycloak client는 public client이며 client secret을 사용하지 않습니다.

Terraform 배포, 모델 관리, Workbook과 로그 쿼리는
[운영 문서](docs/operations.md)를 참고합니다.

## 관련 문서

- [Keycloak Device Authorization Grant](https://www.keycloak.org/docs/latest/server_admin/#_oid4vc_device_authorization_grant)
- [Azure API Management validate-jwt 정책](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [APIM Managed Identity 인증 정책](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [Azure OpenAI Responses API](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/responses)
- [Azure OpenAI Chat Completions](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/chatgpt)
