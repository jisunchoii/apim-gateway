import { homedir } from "node:os"
import { resolve } from "node:path"
import { createDeviceFlowLogger } from "../oidc/device-flow-logger.js"
import { createOidcDeviceCredential } from "../oidc/device-credential.js"
import {
  createFileTokenStore,
  createTokenCacheKey,
} from "../oidc/file-token-store.js"
import { loadClientProfile } from "../oidc/client-profile.js"
import { resolveOidcProvider } from "../oidc/providers.js"

const readSetting = (environmentName, profileValue, defaultValue = "") => {
  const configured = environmentName?.trim()
  if (configured) return configured
  if (typeof profileValue === "string" && profileValue.trim()) {
    return profileValue.trim()
  }
  if (defaultValue) return defaultValue
  return ""
}

export const readOktaClaudeSettings = ({
  env = process.env,
  profile,
  loadProfile = loadClientProfile,
  homeDirectory = homedir(),
  provider = resolveOidcProvider({ env }),
} = {}) => {
  const discoveryFromEnv = env.LLMGW_OIDC_DISCOVERY_URL?.trim()
  const clientFromEnv = env.LLMGW_OIDC_CLIENT_ID?.trim()
  const loaded =
    profile !== undefined
      ? profile
      : discoveryFromEnv && clientFromEnv
        ? null
        : loadProfile({ env, optional: true })
  const discoveryUrl = readSetting(discoveryFromEnv, loaded?.oidc?.discovery_url)
  const clientId = readSetting(clientFromEnv, loaded?.oidc?.client_id)
  const scope = readSetting(
    env.LLMGW_OIDC_SCOPE,
    loaded?.oidc?.scope,
    provider.defaultScope,
  )
  if (!discoveryUrl || !clientId) {
    throw new Error(
      "LLMGW_OIDC_DISCOVERY_URL and LLMGW_OIDC_CLIENT_ID are not set and client_profile is unavailable.",
    )
  }
  provider.validateDiscoveryUrl(discoveryUrl)
  if (
    provider.requireOfflineAccess &&
    !scope.split(/\s+/).includes("offline_access")
  ) {
    throw new Error(
      `The Claude Code ${provider.name} scope must include offline_access for refresh tokens.`,
    )
  }
  const cachePath =
    env.LLMGW_CLAUDE_OIDC_CACHE_PATH?.trim() ||
    resolve(homeDirectory, ".llmgw", provider.cacheFileName)

  return {
    discoveryUrl,
    clientId,
    scope,
    cachePath,
    providerId: provider.id,
    providerName: provider.name,
  }
}

export const createOktaClaudeCredential = ({
  settings = readOktaClaudeSettings(),
  openBrowser = true,
  logger = (message) => process.stderr.write(`${message}\n`),
  tokenStore,
  ...credentialOptions
} = {}) => {
  const cacheKey = createTokenCacheKey(settings)
  return createOidcDeviceCredential({
    providerName: settings.providerName ?? "Okta",
    discoveryUrl: settings.discoveryUrl,
    clientId: settings.clientId,
    scope: settings.scope,
    logger: createDeviceFlowLogger({ openBrowser, logger }),
    tokenStore:
      tokenStore ??
      createFileTokenStore({
        cachePath: settings.cachePath,
        cacheKey,
        providerName: `${settings.providerName ?? "Okta"} Claude Code`,
      }),
    ...credentialOptions,
  })
}
