const deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
const defaultRefreshSkewMs = 60_000

export const AUTH_INTERACTIVE_REQUIRED = "AUTH_INTERACTIVE_REQUIRED"

const interactiveRequiredError = (providerName) => {
  const error = new Error(
    `${providerName} login required. Restart Claude Code to sign in.`,
  )
  error.code = AUTH_INTERACTIVE_REQUIRED
  return error
}

const wait = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds))

const readJson = async (response, label) => {
  const text = await response.text()
  if (!text) return {}

  try {
    return JSON.parse(text)
  } catch (error) {
    throw new Error(`${label} returned invalid JSON.`, { cause: error })
  }
}

const postForm = async (fetchImpl, url, values) => {
  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(values),
  })
  return {
    response,
    payload: await readJson(response, url),
  }
}

const providerError = (providerName, message) =>
  new Error(`${providerName} ${message}`)

const requireHttpUrl = (providerName, value, fieldName) => {
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    throw providerError(providerName, `returned an invalid ${fieldName}.`)
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw providerError(providerName, `returned an invalid ${fieldName}.`)
  }
  return parsed.href
}

const normalizeTokenSet = (
  providerName,
  payload,
  previousRefreshToken,
  now,
) => {
  if (typeof payload.access_token !== "string" || !payload.access_token) {
    throw providerError(providerName, "returned no access_token.")
  }

  const expiresIn = Number(payload.expires_in)
  if (!Number.isFinite(expiresIn) || expiresIn <= 0) {
    throw providerError(providerName, "returned an invalid expires_in value.")
  }

  return {
    accessToken: payload.access_token,
    refreshToken:
      typeof payload.refresh_token === "string" && payload.refresh_token
        ? payload.refresh_token
        : previousRefreshToken,
    expiresAt: now() + expiresIn * 1000,
  }
}

const tokenError = (payload, fallback) => {
  const description =
    typeof payload.error_description === "string"
      ? payload.error_description
      : fallback
  const error = new Error(description)
  error.code = payload.error
  return error
}

export const createOidcDeviceCredential = ({
  providerName = "OIDC provider",
  discoveryUrl,
  clientId,
  scope = "openid",
  fetchImpl = globalThis.fetch,
  logger = (message) => console.error(message),
  now = Date.now,
  sleep = wait,
  refreshSkewMs = defaultRefreshSkewMs,
  tokenStore,
}) => {
  const label = String(providerName).trim() || "OIDC provider"
  if (!discoveryUrl) {
    throw providerError(label, "discoveryUrl is required.")
  }
  if (!clientId) {
    throw providerError(label, "clientId is required.")
  }
  if (!String(scope).trim()) {
    throw providerError(label, "scope is required.")
  }
  if (typeof fetchImpl !== "function") {
    throw new Error("A fetch implementation is required.")
  }

  let discoveryPromise
  let tokenSet
  let storeLoaded = false
  let acquirePromise

  const discover = async () => {
    if (!discoveryPromise) {
      discoveryPromise = (async () => {
        const response = await fetchImpl(discoveryUrl)
        const metadata = await readJson(response, discoveryUrl)
        if (!response.ok) {
          throw tokenError(
            metadata,
            `${label} discovery failed with HTTP ${response.status}.`,
          )
        }
        if (
          typeof metadata.device_authorization_endpoint !== "string" ||
          typeof metadata.token_endpoint !== "string"
        ) {
          throw providerError(
            label,
            "discovery does not advertise device_authorization_endpoint and token_endpoint.",
          )
        }
        return {
          ...metadata,
          device_authorization_endpoint: requireHttpUrl(
            label,
            metadata.device_authorization_endpoint,
            "device_authorization_endpoint",
          ),
          token_endpoint: requireHttpUrl(
            label,
            metadata.token_endpoint,
            "token_endpoint",
          ),
        }
      })()
    }
    return discoveryPromise
  }

  const readStoredToken = async () => {
    if (!tokenStore?.load) return undefined

    const stored = await tokenStore.load()
    if (
      stored &&
      typeof stored.accessToken === "string" &&
      Number.isFinite(stored.expiresAt)
    ) {
      return stored
    }
    return undefined
  }

  const loadStoredToken = async () => {
    if (storeLoaded) return
    storeLoaded = true
    const stored = await readStoredToken()
    if (stored) tokenSet = stored
  }

  const persistToken = async () => {
    if (tokenStore?.save) await tokenStore.save(tokenSet)
  }

  const clearToken = async () => {
    tokenSet = undefined
    if (tokenStore?.clear) await tokenStore.clear()
  }

  const refresh = async (metadata) => {
    const { response, payload } = await postForm(
      fetchImpl,
      metadata.token_endpoint,
      {
        grant_type: "refresh_token",
        client_id: clientId,
        refresh_token: tokenSet.refreshToken,
      },
    )
    if (!response.ok) {
      throw tokenError(
        payload,
        `${label} refresh failed with HTTP ${response.status}.`,
      )
    }

    tokenSet = normalizeTokenSet(
      label,
      payload,
      tokenSet.refreshToken,
      now,
    )
    await persistToken()
    return tokenSet.accessToken
  }

  const authorizeDevice = async (metadata) => {
    const { response, payload } = await postForm(
      fetchImpl,
      metadata.device_authorization_endpoint,
      {
        client_id: clientId,
        scope,
      },
    )
    if (!response.ok) {
      throw tokenError(
        payload,
        `${label} device authorization failed with HTTP ${response.status}.`,
      )
    }
    if (
      typeof payload.device_code !== "string" ||
      typeof payload.user_code !== "string" ||
      typeof payload.verification_uri !== "string"
    ) {
      throw providerError(
        label,
        "returned an invalid device authorization response.",
      )
    }
    const expiresIn = Number(payload.expires_in)
    const interval = payload.interval === undefined ? 5 : Number(payload.interval)
    if (
      !Number.isFinite(expiresIn) ||
      expiresIn <= 0 ||
      !Number.isFinite(interval) ||
      interval <= 0
    ) {
      throw providerError(
        label,
        "returned an invalid device authorization response.",
      )
    }

    const verificationUrl =
      typeof payload.verification_uri_complete === "string"
        ? requireHttpUrl(
            label,
            payload.verification_uri_complete,
            "verification_uri_complete",
          )
        : requireHttpUrl(label, payload.verification_uri, "verification_uri")
    logger(
      [
        `${label} 로그인이 필요합니다.`,
        `브라우저에서 다음 주소를 여세요: ${verificationUrl}`,
        `표시되는 경우 코드를 입력하세요: ${payload.user_code}`,
      ].join("\n"),
    )

    let intervalSeconds = interval
    const expiresAt = now() + expiresIn * 1000

    while (now() < expiresAt) {
      await sleep(intervalSeconds * 1000)
      const tokenResponse = await postForm(fetchImpl, metadata.token_endpoint, {
        grant_type: deviceGrantType,
        device_code: payload.device_code,
        client_id: clientId,
      })
      if (tokenResponse.response.ok) {
        tokenSet = normalizeTokenSet(
          label,
          tokenResponse.payload,
          undefined,
          now,
        )
        await persistToken()
        return tokenSet.accessToken
      }

      switch (tokenResponse.payload.error) {
        case "authorization_pending":
          continue
        case "slow_down":
          intervalSeconds += 5
          continue
        case "expired_token":
          throw providerError(
            label,
            "device code expired before login completed.",
          )
        case "access_denied":
          throw providerError(label, "device login was denied.")
        default:
          throw tokenError(
            tokenResponse.payload,
            `${label} token polling failed with HTTP ${tokenResponse.response.status}.`,
          )
      }
    }

    throw providerError(label, "device code expired before login completed.")
  }

  const acquire = async ({ interactive = true } = {}) => {
    await loadStoredToken()
    if (tokenSet?.accessToken && tokenSet.expiresAt - now() > refreshSkewMs) {
      return tokenSet.accessToken
    }

    const metadata = await discover()
    if (tokenSet?.refreshToken) {
      try {
        return await refresh(metadata)
      } catch (error) {
        if (error.code !== "invalid_grant") throw error
        const failedRefreshToken = tokenSet.refreshToken
        const reloaded = await readStoredToken()
        if (reloaded && reloaded.refreshToken !== failedRefreshToken) {
          tokenSet = reloaded
          if (
            tokenSet.accessToken &&
            tokenSet.expiresAt - now() > refreshSkewMs
          ) {
            return tokenSet.accessToken
          }
          if (tokenSet.refreshToken) {
            try {
              return await refresh(metadata)
            } catch (retryError) {
              if (retryError.code !== "invalid_grant") throw retryError
            }
          }
        }
        await clearToken()
      }
    }
    if (!interactive) throw interactiveRequiredError(label)
    return authorizeDevice(metadata)
  }

  const forceRefresh = async ({ interactive = false } = {}) => {
    await loadStoredToken()
    const metadata = await discover()
    if (tokenSet?.refreshToken) {
      try {
        return await refresh(metadata)
      } catch (error) {
        if (error.code !== "invalid_grant") throw error
        await clearToken()
      }
    }
    if (!interactive) throw interactiveRequiredError(label)
    return authorizeDevice(metadata)
  }

  const runExclusive = (work) => {
    if (!acquirePromise) {
      acquirePromise = work().finally(() => {
        acquirePromise = undefined
      })
    }
    return acquirePromise
  }

  return {
    getToken: async (options = {}) => runExclusive(() => acquire(options)),
    forceRefresh: async (options = {}) =>
      runExclusive(() => forceRefresh(options)),
    clear: clearToken,
  }
}
