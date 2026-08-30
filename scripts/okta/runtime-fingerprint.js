import { createHash } from "node:crypto"

export const normalizeBaseUrl = (value) => String(value ?? "").replace(/\/+$/, "")

export const fingerprintFrom = (value) =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex")

export const authProxyFingerprint = ({
  baseUrl,
  discoveryUrl,
  clientId,
  scope,
  port,
}) =>
  fingerprintFrom({
    kind: "llmgw-okta-auth-proxy",
    baseUrl: normalizeBaseUrl(baseUrl),
    discoveryUrl: String(discoveryUrl ?? ""),
    clientId: String(clientId ?? ""),
    scope: String(scope ?? ""),
    port: Number(port),
  })

export const openCodexFingerprint = ({ config, authProxyPort }) =>
  fingerprintFrom({
    kind: "opencodex",
    port: config?.port,
    hostname: config?.hostname,
    providers: config?.providers,
    claudeCode: config?.claudeCode,
    authProxyPort: Number(authProxyPort),
  })
