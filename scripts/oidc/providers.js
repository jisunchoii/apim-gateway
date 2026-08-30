import { oktaOidcProvider } from "./providers/okta.js"

export { oktaOidcProvider }

export const oidcProviders = {
  okta: oktaOidcProvider,
}

export const defaultOidcProviderId = "okta"

export const resolveOidcProvider = ({ env = process.env } = {}) => {
  const id = env.LLMGW_OIDC_PROVIDER?.trim() || defaultOidcProviderId
  const provider = oidcProviders[id]
  if (!provider) {
    throw new Error(`Unknown OIDC provider: ${id}`)
  }
  return provider
}
