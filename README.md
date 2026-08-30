# LLM Gateway 사용 안내

이 Gateway는 회사에서 승인한 Microsoft Foundry 모델을 OpenAI 호환 API로 제공합니다. 최종 사용자는
OIDC Device Authorization Grant로 로그인하고 Azure API Management(APIM)에 bearer token을
보냅니다. 서비스 계정은 별도 API에 APIM subscription key를 보냅니다. 두 API 모두 APIM Managed
Identity와 Azure RBAC로 Foundry backend를 호출합니다.

Claude Code에서 GPT/OSS 모델을 쓰려면
[온보딩 가이드](docs/claude-code-gpt-oss-onboarding.md)를 Azure부터 로컬 실행까지 따라갑니다.
공식 Claude Code + Foundry 경로는 Claude 모델용입니다.

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

OIDC 연결에는 다음 값이 필요합니다.

| 항목 | 예시 |
|---|---|
| Discovery URL | `https://<oidc-provider>/.../.well-known/openid-configuration` |
| Public client ID | `<public-client-id>` |
| Requested scope | `openid offline_access llm-gateway` |
| API audience | `llm-gateway-api` |
| Role claim | `llm_gateway_roles` |
| Required role | `invoke` |
| User label claim | `llm_gateway_user` |

OIDC provider에서 `llm-gateway` scope와 `llm_gateway_roles: ["invoke"]` claim을 받을 수 있는
계정이 있어야 합니다. 고객 PC에 client secret을 배포하지 않으며, 최초 로그인 시 브라우저에서
user code를 승인합니다.

최종 사용자 호출은 Claude Code 경로(`npm run claude`)를 사용합니다. API를 직접 확인하려면
아래 서비스 계정 연결을 사용합니다.

## 빠른 연결 확인

### 서비스 계정 연결

서비스 계정은 `Service Model Gateway` API 범위로 발급된 고유 subscription key를 사용합니다.
사용자 OIDC token은 보내지 않으며, 키는 `Ocp-Apim-Subscription-Key` header로 전달합니다.
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

Gateway base URL에는 이미 `/openai/v1`이 포함되어 있습니다.

| Method | Suffix | 용도 |
|---|---|---|
| `POST` | `/responses` | OpenAI Responses 형식입니다. GPT 계열에 권장합니다. |
| `POST` | `/chat/completions` | OpenAI Chat Completions 형식입니다. Responses를 지원하지 않는 모델에 사용합니다. |

다음 API는 현재 제공하지 않습니다.

- `GET /models`
- `POST /responses/compact`
- Anthropic `POST /v1/messages`
- Embeddings, Images, Audio API

미지원 경로는 일반적으로 `404`를 반환합니다.

### 공통 요청 규칙

최종 사용자 API는 OIDC bearer token, 서비스 계정 API는
`Ocp-Apim-Subscription-Key` header가 필요합니다. 두 API 모두
`Content-Type: application/json`과 정확한 `model` 이름을 사용합니다. APIM은 인증 후
`routed_models`에 해당하는 Foundry backend를 선택하고 Managed Identity로 요청을 전달합니다.

`POST /chat/completions`는 legacy `max_tokens`를 `max_completion_tokens`로 변환하고 streaming
사용량 집계를 활성화합니다. `POST /responses`는 Responses 형식을 유지하며 backend가 받지 않는
Chat 전용 `stream_options`를 제거합니다. role 기반 `input` item의 `type`이 비어 있으면 Foundry
Responses 형식에 맞게 `type: "message"`를 채웁니다.

## Coding agent 설정

### Claude Code + GPT/OSS (실험적)

전체 절차는 [Claude Code GPT/OSS 온보딩](docs/claude-code-gpt-oss-onboarding.md)입니다.
Okta 화면 구성은 [Okta 관리자 가이드](docs/okta-admin-guide.md)입니다.

```powershell
npm ci
$env:LLMGW_CLIENT_PROFILE = "C:\path\to\client-profile.json"
npm run claude
```

| 명령 | 동작 |
|---|---|
| `npm run claude` | 설정 후 Claude Code 시작 |
| `npm run claude:configure` | OpenCodex/Claude 설정만 생성 |
| `npm run claude:doctor` | 비밀 없이 연결 상태 확인 |
| `npm run claude:restart` | 로컬 서비스를 종료한 뒤 다시 시작 |
| `npm run claude:down` | OpenCodex와 인증 프록시 종료 |

`npm ci`가 pinned OpenCodex를 설치합니다. global `opencodex` 설치는 필요 없습니다.

## 오류 대응

| 상태 | 의미 | 고객 조치 |
|---|---|---|
| `400` | 잘못된 JSON 또는 `model` 누락 | request body와 모델 이름을 확인합니다. |
| `401` | 사용자 token 또는 서비스 subscription key 누락·오류 | 사용자는 `npm run claude`로 다시 로그인하고, 서비스는 subscription key를 확인합니다. |
| `403` | Gateway에 라우팅되지 않은 모델 | 현재 지원 모델을 운영자에게 확인합니다. |
| `404` | 등록되지 않은 API 경로 | `/responses` 또는 `/chat/completions`를 사용합니다. |
| `429` | 사용자 제한 또는 backend TPM/RPM 제한 | `Retry-After`를 따르고 exponential backoff를 적용합니다. |
| `500` | backend 연결 또는 처리 실패 | 무제한 재시도를 피하고 잠시 후 제한적으로 재시도합니다. |
| `503` | circuit breaker 또는 일시적 backend 불가 | `Retry-After` 후 제한적으로 재시도합니다. |

문제를 신고할 때는 발생 시각과 시간대, 모델, API suffix, HTTP status와 응답 body를 전달합니다.
Prompt, access token, refresh token과 고객 데이터는 지원 요청에 첨부하지 않습니다.

## 보안과 사용량 기록

- 고객 인증은 OIDC Device Authorization Grant로 수행합니다.
- 서비스 계정 인증은 별도 API의 APIM API-scoped subscription으로 수행합니다.
- APIM에서 Foundry로의 인증은 Managed Identity와 Azure RBAC를 사용합니다.
- APIM은 OIDC token의 `iss:sub`를 SHA-256으로 해시하여 사용자별 사용량을 집계합니다.
- Workbook 표시용 OIDC user label은 `userLabel`로 Azure Monitor trace에 저장됩니다.
- Gateway 진단 로그에는 prompt와 model output을 저장하지 않습니다.
- Terminal OIDC client는 public client이며 client secret을 사용하지 않습니다.

Terraform 배포, 모델 관리, Workbook과 로그 쿼리는
[운영 문서](docs/operations.md)를 참고합니다.

## 관련 문서

- [온보딩 가이드](docs/claude-code-gpt-oss-onboarding.md)
- [Okta 관리자 가이드](docs/okta-admin-guide.md)
- [운영 문서](docs/operations.md)
- [Okta Device Authorization Grant](https://developer.okta.com/docs/guides/device-authorization-grant/main/)
- [Azure API Management validate-jwt 정책](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [Azure API Management subscriptions](https://learn.microsoft.com/azure/api-management/api-management-subscriptions)
- [APIM Managed Identity 인증 정책](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [Azure OpenAI Responses API](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/responses)
- [Azure OpenAI Chat Completions](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/chatgpt)
- [Claude Code LLM gateway](https://code.claude.com/docs/en/llm-gateway)
- [OpenCodex Claude Code integration](https://opencodex.me/guides/claude-code/)
- [Configure Claude Code for Microsoft Foundry](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-claude-code)
