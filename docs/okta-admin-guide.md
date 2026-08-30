# Okta 관리자 가이드

고객이 Azure부터 Claude Code까지 한 번에 구축할 때는
[온보딩 가이드](claude-code-gpt-oss-onboarding.md)를 먼저 보고, 이 문서는 Okta Admin Console
절차만 참고합니다.

Okta는 우리 API를 보호할 때 **Custom Authorization Server**를 쓰라고 합니다. Org Authorization
Server 토큰은 Okta 자신(SSO, Okta API)용이며 audience·scope·claim을 커스텀할 수 없고, 이
게이트웨이의 `llm-gateway-api` / `llm-gateway` / `llm_gateway_roles` 계약을 맞출 수 없습니다.

- [Authorization servers](https://developer.okta.com/docs/concepts/auth-servers/)
- [API Access Management](https://developer.okta.com/docs/concepts/api-access-management/)

운영 Okta에서는 Custom AS가 **API Access Management** 애드온입니다. 고객 조직의
**Security > API > Authorization Servers**가 없으면 그 기능을 요청합니다.

이 저장소를 검증할 때는 고객 조직이 없어도 됩니다. Okta [Integrator Free Plan](https://developer.okta.com/signup/)
조직은 테스트용으로 Custom Authorization Server를 기본 제공합니다. 고객 온보딩에서 Free Plan을
가입하라는 뜻이 아닙니다.

Okta는 로컬 서버가 아니라 SaaS tenant입니다. APIM에는 한 번에 하나의 최종 사용자 OIDC
provider만 설정됩니다.

## 보안 경계

- Claude Code 런타임은 관리자 token이나 client secret을 사용하지 않습니다.
- 런타임 인증은 public Native OIDC application의 Device Authorization Grant를 사용합니다.
- tenant URL, client ID, 사용자 정보, token, tfvars는 저장소에 commit하지 않습니다.
- APIM은 OIDC access token을 검증한 뒤 제거하고 Microsoft Foundry에는 APIM Managed Identity
  token만 전달합니다.

## 1. Okta 조직 준비

### 고객 운영 조직

1. 고객 Okta Admin Console에 관리자로 로그인합니다.
2. **Security > API > Authorization Servers**에서 Custom Authorization Server를 만들 수
   있는지 확인합니다.
3. 게이트웨이를 호출할 사용자가 Directory에 있고 로그인할 수 있는지 확인합니다.

### 테스트용 Integrator Free Plan

고객 조직에 API Access Management가 아직 없을 때, 이 저장소의 Custom AS 경로를 검증하려면:

1. [Integrator Free Plan](https://developer.okta.com/signup/) 조직을 만들고 이메일 확인과
   관리자 로그인을 완료합니다.
2. **Directory > People**에서 테스트 사용자를 만들고 로그인 가능한지 확인합니다.
3. **Security > API > Authorization Servers**에 `default` Custom AS가 보이는지 확인합니다.
   Free Plan org는 테스트용으로 이 기능이 켜져 있습니다.
4. 자동화에 관리자 API token을 쓰면 **Security > API > Tokens**에서 만들고, 구성이 끝나면
   같은 화면에서 revoke합니다. token은 저장소에 커밋하지 않습니다.

## 2. 필요한 Okta 리소스

Admin Console에서 아래 값을 구성합니다. 이름·그룹은 환경에 맞게 바꿔도 되지만, Terraform
`oidc_provider`의 audience, scope, claim, role과 일치해야 합니다.

### 그룹

**Directory > Groups**에서 이름이 정확히 `invoke`인 Okta group을 만들고 게이트웨이 사용자를
추가합니다. 이 이름은 access token의 `llm_gateway_roles` 배열에 들어가며 APIM의 required role과
일치해야 합니다. 기존 그룹을 쓰려면 claim 필터와 `required_role`을 그 이름에 맞춥니다.

### Custom Authorization Server

**Security > API > Authorization Servers > Add Authorization Server**에서 다음 값을 사용합니다.

| 항목 | 값 |
|---|---|
| Name | `LLM Gateway` |
| Audience | `llm-gateway-api` |
| Description | `LLM Gateway Claude Code authorization server` |

생성된 authorization server의 ID를 기록합니다. issuer와 discovery URL은 다음 형식입니다.

```text
https://<okta-domain>/oauth2/<authorization-server-id>
https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration
```

**Scopes** 탭에서 다음 custom scope를 추가합니다.

| 항목 | 값 |
|---|---|
| Name | `llm-gateway` |
| Display phrase | `LLM Gateway` |
| Consent | Implicit |
| Include in public metadata | Enabled |

**Claims** 탭에서 access token claim 두 개를 추가합니다.

| Name | Value type | Value | Include in token |
|---|---|---|---|
| `llm_gateway_roles` | Groups | Equals `invoke` | Access token, `llm-gateway` scope |
| `llm_gateway_user` | Expression | `user.login` | Access token, `llm-gateway` scope |

`llm_gateway_roles`는 사용자가 `invoke` group에 속할 때 `["invoke"]`를 반환해야 합니다.

### Native OIDC application

**Applications > Applications > Create App Integration**에서 다음과 같이 만듭니다.

| 항목 | 값 |
|---|---|
| Sign-in method | OIDC |
| Application type | Native Application |
| App name | `LLM Gateway Claude Code` |
| Grant types | Device Authorization, Refresh Token |
| Client authentication | None |
| Assignments | `invoke` group |

Native application의 Client ID를 기록합니다. client secret을 만들거나 배포하지 않습니다.

### Access policy

Custom Authorization Server의 **Access Policies** 탭에서 위 Native application만 대상으로 하는
policy를 만들고 rule을 추가합니다.

| 항목 | 값 |
|---|---|
| Grant types | Device Authorization |
| Users | `invoke` group |
| Scopes | `openid`, `offline_access`, `llm-gateway` |
| Access token lifetime | 60 minutes |
| Refresh token lifetime | 운영 정책에 맞는 제한된 값 |

`Refresh Token` grant는 Native application에서 활성화합니다. Authorization Server policy rule의
grant condition에는 `Device Authorization`만 선택합니다.

## 3. Discovery 확인

브라우저나 OS별 명령으로 discovery document를 조회합니다.

PowerShell:

```powershell
$discovery = Invoke-RestMethod "https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"
$discovery.issuer
$discovery.device_authorization_endpoint
$discovery.token_endpoint
$discovery.jwks_uri
```

Bash / Linux:

```bash
export DISCOVERY_URL="https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"

node -e '
fetch(process.env.DISCOVERY_URL)
  .then((response) => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
  })
  .then(({ issuer, device_authorization_endpoint, token_endpoint, jwks_uri }) => {
    console.log({ issuer, device_authorization_endpoint, token_endpoint, jwks_uri })
  })
'
```

네 값이 모두 HTTPS URL이어야 하며 `issuer`는 Terraform에 전달할 값과 정확히 일치해야 합니다.

## 4. Terraform `oidc_provider`

`infra/terraform.tfvars`의 `oidc_provider`에 아래 값을 넣습니다.

```hcl
oidc_provider = {
  openid_config_url = "https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"
  audience          = "llm-gateway-api"
  issuer            = "https://<okta-domain>/oauth2/<authorization-server-id>"
  client_id         = "<native-app-client-id>"
  client_scope      = "openid offline_access llm-gateway"
  required_scope    = "llm-gateway"
  scope_claim       = "scp"
  role_claim        = "llm_gateway_roles"
  required_role     = "invoke"
  user_label_claim  = "llm_gateway_user"
}
```

`terraform -chdir=infra plan`에서 `oidc_provider`가 의도한 Okta 값인지 확인합니다. 다른 IdP로
바뀌는 diff가 있으면 apply하지 않습니다. Azure APIM의 `validate-jwt` 정책은 discovery와 JWKS를
통해 서명, issuer, audience, 만료와 required claim을 검증합니다.

Microsoft 공식 문서:

- [Azure API Management `validate-jwt` policy](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [APIM managed identity authentication policy](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)

## 5. Claude Code 실행

저장소 루트에서 OS별 명령으로 tenant 값을 환경 변수에 설정합니다.

Windows PowerShell:

```powershell
npm ci

$env:LLMGW_BASE_URL = "https://<apim-name>.azure-api.net/openai/v1"
$env:LLMGW_OIDC_DISCOVERY_URL = "https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"
$env:LLMGW_OIDC_CLIENT_ID = "<native-app-client-id>"
$env:LLMGW_OIDC_SCOPE = "openid offline_access llm-gateway"

npm run claude
```

Bash / Linux:

```bash
npm ci

export LLMGW_BASE_URL="https://<apim-name>.azure-api.net/openai/v1"
export LLMGW_OIDC_DISCOVERY_URL="https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"
export LLMGW_OIDC_CLIENT_ID="<native-app-client-id>"
export LLMGW_OIDC_SCOPE="openid offline_access llm-gateway"

npm run claude
```

브라우저에서 user code를 승인하면 Okta access/refresh token과 OpenCodex 설정은 다음 경로에
저장됩니다.

| 항목 | Windows | Linux |
|---|---|---|
| Token cache | `%USERPROFILE%\.llmgw\okta-claude-token.json` | `~/.llmgw/okta-claude-token.json` |
| OpenCodex profile | `%USERPROFILE%\.llmgw\opencodex-okta` | `~/.llmgw/opencodex-okta` |

`npm run claude`는 전용 OpenCodex profile과 Claude Code settings(SessionStart hook)를
구성한 뒤 Okta Device Flow 인증과 로컬 인증 프록시 준비를 먼저 완료하고 `ocx claude`를
실행합니다. 최초 세션에서만 브라우저 승인이 필요하고 이후 세션은 cache된 refresh token으로
자동 인증됩니다. 설정만 생성하려면 `npm run claude:configure`, 연결 확인은
`npm run claude:doctor`를 실행합니다.

GUI가 없는 Linux, SSH, Cloud Shell에서는 브라우저가 자동으로 열리지 않습니다. 터미널에
표시되는 verification URL을 로컬 PC 브라우저에서 열고 user code를 입력합니다.

## 6. 로컬 런타임 종료

OpenCodex와 인증 프록시는 재사용을 위해 백그라운드에 남습니다. 끄려면
`npm run claude:down`을 실행합니다.

고객 운영 조직의 authorization server와 application은 삭제하지 않습니다. Integrator Free Plan
테스트 조직은 검증이 끝나면 Admin Console에서 authorization server, application, group을
제거하고 관리자 API token을 revoke합니다.

## 공식 참고 문서

- [Okta Device Authorization Grant](https://developer.okta.com/docs/guides/device-authorization-grant/main/)
- [Okta authorization servers](https://developer.okta.com/docs/concepts/auth-servers/)
- [Okta API Access Management](https://developer.okta.com/docs/concepts/api-access-management/)
- [Okta custom authorization servers](https://developer.okta.com/docs/guides/customize-authz-server/main/)
- [Okta groups claim](https://developer.okta.com/docs/guides/customize-tokens-groups-claim/main/)
- [Okta Authorization Servers API](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/AuthorizationServer/)
- [Okta Applications API](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/Application/)
- [Claude Code LLM gateway](https://code.claude.com/docs/en/llm-gateway)
- [OpenCodex Claude Code integration](https://opencodex.me/guides/claude-code/)
