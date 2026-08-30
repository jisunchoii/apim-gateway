# Okta Claude Code 테스트 관리자 가이드

고객이 Azure부터 Claude Code까지 한 번에 구축할 때는
[온보딩 가이드](claude-code-gpt-oss-onboarding.md)를 먼저 보고, 이 문서는 Okta Admin Console
절차만 참고합니다.

이 문서는 Okta Integrator Free Plan 조직을 LLM Gateway의 Claude Code 테스트용 OIDC provider로
구성하는 절차입니다. Okta는 로컬 서버가 아니라 SaaS tenant입니다. APIM에는 한 번에 하나의
최종 사용자 OIDC provider만 설정됩니다.

## 보안 경계

- Okta 관리자 API token은 초기 구성에만 사용하고 완료 후 폐기합니다.
- Claude Code 런타임은 관리자 token이나 client secret을 사용하지 않습니다.
- 런타임 인증은 public Native OIDC application의 Device Authorization Grant를 사용합니다.
- tenant URL, client ID, 사용자 정보, token, 생성된 tfvars와 OpenCodex profile은 저장소에
  commit하지 않습니다.
- APIM은 OIDC access token을 검증한 뒤 제거하고 Microsoft Foundry에는 APIM Managed Identity
  token만 전달합니다.

## 1. Integrator Free Plan 조직 준비

1. [Okta Integrator Free Plan](https://developer.okta.com/signup/) 조직을 생성하고 이메일 확인과
   첫 관리자 로그인을 완료합니다.
2. 테스트 사용자가 없다면 **Directory > People**에서 생성하고 로그인이 가능한지 확인합니다.
3. 자동 bootstrap을 사용할 경우 **Security > API > Tokens**에서 임시 API token을 생성합니다.
   token은 환경 변수로만 전달하고 구성 직후 같은 화면에서 revoke합니다.

## 2. 필요한 Okta 리소스

세션 전용 bootstrap script를 사용하지 않는 경우 아래 값을 Admin Console에서 직접 구성합니다.

### 그룹

**Directory > Groups**에서 이름이 정확히 `invoke`인 Okta group을 만들고 테스트 사용자를
추가합니다. 이 이름은 access token의 `llm_gateway_roles` 배열에 들어가며 APIM의 required role과
일치해야 합니다.

### Custom Authorization Server

**Security > API > Authorization Servers > Add Authorization Server**에서 다음 값을 사용합니다.

| 항목 | 값 |
|---|---|
| Name | `LLM Gateway Test` |
| Audience | `llm-gateway-api` |
| Description | `Claude Code Okta test authorization server` |

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

`llm_gateway_roles`는 테스트 사용자가 `invoke` group에 속할 때 `["invoke"]`를 반환해야 합니다.

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
| Refresh token lifetime | 테스트 기간에 맞는 제한된 값 |

`Refresh Token` grant는 Native application에서 활성화합니다. Authorization Server policy rule의
grant condition에는 `Device Authorization`만 선택합니다.

## 3. Discovery 확인

브라우저나 PowerShell에서 discovery document를 조회합니다.

```powershell
$discovery = Invoke-RestMethod "https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"
$discovery.issuer
$discovery.device_authorization_endpoint
$discovery.token_endpoint
$discovery.jwks_uri
```

네 값이 모두 HTTPS URL이어야 하며 `issuer`는 Terraform에 전달할 값과 정확히 일치해야 합니다.

## 4. APIM 임시 Okta override

기존 `infra\terraform.tfvars`는 변경하지 않습니다. 저장소 밖이나 gitignore 대상 경로에
`okta.tfvars`를 만들고 다음 값을 넣습니다.

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

원래 tfvars 뒤에 override를 지정해 plan을 확인합니다.

```powershell
terraform -chdir=infra plan -var-file=terraform.tfvars -var-file="<absolute-path>\okta.tfvars"
```

OIDC 관련 APIM policy 값 외의 변경이 보이면 apply하지 않습니다. 예상된 plan만 확인한 후 같은
두 `-var-file` 인수로 apply합니다. Azure APIM의 `validate-jwt` 정책은 discovery와 JWKS를 통해
서명, issuer, audience, 만료와 required claim을 검증합니다.

Microsoft 공식 문서:

- [Azure API Management `validate-jwt` policy](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [APIM managed identity authentication policy](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)

## 5. Claude Code 실행

저장소 루트의 PowerShell에서 tenant별 값을 환경 변수로 설정합니다.

```powershell
npm ci

$env:LLMGW_BASE_URL = "https://<apim-name>.azure-api.net/openai/v1"
$env:LLMGW_OIDC_DISCOVERY_URL = "https://<okta-domain>/oauth2/<authorization-server-id>/.well-known/openid-configuration"
$env:LLMGW_OIDC_CLIENT_ID = "<native-app-client-id>"
$env:LLMGW_OIDC_SCOPE = "openid offline_access llm-gateway"

npm run claude
```

브라우저에서 user code를 승인하면 Okta access/refresh token은
`%USERPROFILE%\.llmgw\okta-claude-token.json`에 저장됩니다. OpenCodex 설정은 별도
`%USERPROFILE%\.llmgw\opencodex-okta` profile에 생성됩니다.

`npm run claude`는 전용 OpenCodex profile과 Claude Code settings(SessionStart hook)를
구성한 뒤 `ocx claude`를 실행합니다. Claude Code가 시작될 때 SessionStart hook이 Okta Device
Flow 인증을 수행하고 로컬 인증 프록시를 기동하므로, 최초 세션에서만 브라우저 승인이
필요하고 이후 세션은 cache된 refresh token으로 자동 인증됩니다. 설정만 생성하려면
`npm run claude:configure`, 연결 확인은 `npm run claude:doctor`를 실행합니다.

## 6. 테스트 종료

1. OpenCodex와 인증 프록시는 재사용을 위해 백그라운드에 유지되므로, 종료하려면
   `npm run claude:down`을 실행합니다.
2. Okta 관리자 API token을 revoke합니다.
3. Okta 리소스를 삭제할 때는 Admin Console에서 authorization server, application, group만
   제거합니다.
4. 더 이상 필요하지 않으면 전용 token cache와 OpenCodex profile을 삭제합니다.

## 공식 참고 문서

- [Okta Device Authorization Grant](https://developer.okta.com/docs/guides/device-authorization-grant/main/)
- [Okta custom authorization servers](https://developer.okta.com/docs/guides/customize-authz-server/main/)
- [Okta groups claim](https://developer.okta.com/docs/guides/customize-tokens-groups-claim/main/)
- [Okta Authorization Servers API](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/AuthorizationServer/)
- [Okta Applications API](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/Application/)
- [Claude Code LLM gateway](https://code.claude.com/docs/en/llm-gateway)
- [OpenCodex Claude Code integration](https://opencodex.me/guides/claude-code/)
