const deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
const defaultRefreshSkewMs = 60_000

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

const normalizeTokenSet = (payload, previousRefreshToken, now) => {
  if (typeof payload.access_token !== "string" || !payload.access_token) {
    throw new Error("Keycloak returned no access_token.")
  }

  const expiresIn = Number(payload.expires_in)
  if (!Number.isFinite(expiresIn) || expiresIn <= 0) {
    throw new Error("Keycloak returned an invalid expires_in value.")
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

export const createKeycloakDeviceCredential = ({
  discoveryUrl,
  clientId,
  scope = "openid llm-gateway",
  fetchImpl = globalThis.fetch,
  logger = (message) => console.error(message),
  now = Date.now,
  sleep = wait,
  refreshSkewMs = defaultRefreshSkewMs,
  tokenStore,
}) => {
  if (!discoveryUrl) {
    throw new Error("Keycloak discoveryUrl is required.")
  }
  if (!clientId) {
    throw new Error("Keycloak clientId is required.")
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
            `Keycloak discovery failed with HTTP ${response.status}.`,
          )
        }
        if (
          typeof metadata.device_authorization_endpoint !== "string" ||
          typeof metadata.token_endpoint !== "string"
        ) {
          throw new Error(
            "Keycloak discovery does not advertise device_authorization_endpoint and token_endpoint.",
          )
        }
        return metadata
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
    if (stored) {
      tokenSet = stored
    }
  }

  const persistToken = async () => {
    if (tokenStore?.save) {
      await tokenStore.save(tokenSet)
    }
  }

  const clearToken = async () => {
    tokenSet = undefined
    if (tokenStore?.clear) {
      await tokenStore.clear()
    }
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
        `Keycloak refresh failed with HTTP ${response.status}.`,
      )
    }

    tokenSet = normalizeTokenSet(payload, tokenSet.refreshToken, now)
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
        `Keycloak device authorization failed with HTTP ${response.status}.`,
      )
    }
    if (
      typeof payload.device_code !== "string" ||
      typeof payload.user_code !== "string" ||
      typeof payload.verification_uri !== "string"
    ) {
      throw new Error("Keycloak returned an invalid device authorization response.")
    }

    const verificationUrl =
      typeof payload.verification_uri_complete === "string"
        ? payload.verification_uri_complete
        : payload.verification_uri
    logger(
      [
        "Keycloak 로그인이 필요합니다.",
        `브라우저에서 다음 주소를 여세요: ${verificationUrl}`,
        `표시되는 경우 코드를 입력하세요: ${payload.user_code}`,
      ].join("\n"),
    )

    let intervalSeconds = Math.max(Number(payload.interval) || 5, 1)
    const expiresAt = now() + Math.max(Number(payload.expires_in) || 600, 1) * 1000

    while (now() < expiresAt) {
      await sleep(intervalSeconds * 1000)
      const tokenResponse = await postForm(fetchImpl, metadata.token_endpoint, {
        grant_type: deviceGrantType,
        device_code: payload.device_code,
        client_id: clientId,
      })
      if (tokenResponse.response.ok) {
        tokenSet = normalizeTokenSet(tokenResponse.payload, undefined, now)
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
          throw new Error("Keycloak device code expired before login completed.")
        case "access_denied":
          throw new Error("Keycloak device login was denied.")
        default:
          throw tokenError(
            tokenResponse.payload,
            `Keycloak token polling failed with HTTP ${tokenResponse.response.status}.`,
          )
      }
    }

    throw new Error("Keycloak device code expired before login completed.")
  }

  const acquire = async () => {
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
        // Another process may have rotated the refresh token via the shared
        // store; adopt it before falling back to device authorization.
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
    return authorizeDevice(metadata)
  }

  return {
    getToken: async () => {
      if (!acquirePromise) {
        acquirePromise = acquire().finally(() => {
          acquirePromise = undefined
        })
      }
      return acquirePromise
    },
    clear: clearToken,
  }
}
