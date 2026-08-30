export const oktaOidcProvider = {
  id: "okta",
  name: "Okta",
  defaultScope: "openid offline_access llm-gateway",
  cacheFileName: "okta-claude-token.json",
  profileHomeName: "opencodex-okta",
  requireOfflineAccess: true,
  validateDiscoveryUrl(discoveryUrl) {
    let pathname
    try {
      pathname = new URL(discoveryUrl).pathname
    } catch {
      throw new Error("The configured OIDC discovery URL is invalid.")
    }
    if (/\/realms\//i.test(pathname)) {
      throw new Error(
        "The configured OIDC discovery URL points to Keycloak. Set LLMGW_OIDC_DISCOVERY_URL and LLMGW_OIDC_CLIENT_ID to the Okta application values.",
      )
    }
  },
}
