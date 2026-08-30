#!/usr/bin/env node

import { createServer } from "node:http"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"
import { pathToFileURL } from "node:url"
import { AUTH_INTERACTIVE_REQUIRED } from "../oidc/device-credential.js"
import { resolveGatewayBaseUrl } from "../oidc/client-profile.js"
import { createOktaClaudeCredential, readOktaClaudeSettings } from "./claude-credential.js"
import { authProxyFingerprint, normalizeBaseUrl } from "./runtime-fingerprint.js"

const defaultHost = "127.0.0.1"
const defaultPort = 10101
const defaultMaxRequestBytes = 32 * 1024 * 1024
const requestHeaderBlocklist = new Set([
  "authorization",
  "x-api-key",
  "ocp-apim-subscription-key",
  "host",
  "content-length",
  "connection",
  "proxy-connection",
  "keep-alive",
  "transfer-encoding",
  "upgrade",
  "accept-encoding",
])
const responseHeaderBlocklist = new Set([
  "connection",
  "proxy-connection",
  "keep-alive",
  "transfer-encoding",
  "upgrade",
  "content-length",
  "content-encoding",
])

const readPositiveInteger = (value, fallback, name) => {
  if (value === undefined || value === "") return fallback
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer.`)
  }
  return parsed
}

const readGatewayBaseUrl = ({ env = process.env } = {}) =>
  resolveGatewayBaseUrl({ env })

const writeJson = (response, statusCode, payload) => {
  if (response.headersSent) return
  const body = Buffer.from(JSON.stringify(payload))
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": body.length,
  })
  response.end(body)
}

const readRequestBody = async (request, maxBytes) => {
  const chunks = []
  let totalBytes = 0
  for await (const chunk of request) {
    totalBytes += chunk.length
    if (totalBytes > maxBytes) {
      const error = new Error(`Request body exceeds ${maxBytes} bytes.`)
      error.code = "REQUEST_TOO_LARGE"
      throw error
    }
    chunks.push(chunk)
  }
  return Buffer.concat(chunks, totalBytes)
}

const copyRequestHeaders = (headers) => {
  const result = new Headers()
  for (const [name, value] of Object.entries(headers)) {
    if (
      value === undefined ||
      requestHeaderBlocklist.has(name.toLowerCase())
    ) {
      continue
    }
    if (Array.isArray(value)) {
      for (const entry of value) result.append(name, entry)
    } else {
      result.set(name, value)
    }
  }
  return result
}

const copyResponseHeaders = (source, target) => {
  source.forEach((value, name) => {
    if (!responseHeaderBlocklist.has(name.toLowerCase())) {
      target.setHeader(name, value)
    }
  })
}

const routeForPath = (pathname) => {
  if (pathname === "/v1/responses" || pathname === "/responses") {
    return "/responses"
  }
  if (
    pathname === "/v1/chat/completions" ||
    pathname === "/chat/completions"
  ) {
    return "/chat/completions"
  }
  return null
}

const cancelBody = async (response) => {
  try {
    await response.body?.cancel()
  } catch {
    // The upstream may already have closed the rejected response body.
  }
}

export const startOktaAuthProxy = async ({
  host = defaultHost,
  port = defaultPort,
  baseUrl = readGatewayBaseUrl(),
  credential = createOktaClaudeCredential(),
  fingerprint,
  fetchImpl = globalThis.fetch,
  logger = (message) => process.stderr.write(`${message}\n`),
  maxRequestBytes = defaultMaxRequestBytes,
  allowInsecureUpstream = false,
} = {}) => {
  if (host !== "127.0.0.1" && host !== "::1" && host !== "localhost") {
    throw new Error("Okta auth proxy must bind to a loopback host.")
  }
  if (typeof fetchImpl !== "function") {
    throw new Error("A fetch implementation is required.")
  }
  if (
    !Number.isSafeInteger(port) ||
    port < 0 ||
    port > 65535 ||
    !Number.isSafeInteger(maxRequestBytes) ||
    maxRequestBytes <= 0
  ) {
    throw new Error("Proxy port or maximum request size is invalid.")
  }

  const upstreamBaseUrl = new URL(baseUrl)
  if (
    upstreamBaseUrl.protocol !== "https:" &&
    !(allowInsecureUpstream && upstreamBaseUrl.protocol === "http:")
  ) {
    throw new Error("LLMGW_BASE_URL must use HTTPS.")
  }
  const resolvedFingerprint =
    fingerprint ??
    authProxyFingerprint({
      baseUrl: normalizeBaseUrl(upstreamBaseUrl.href),
      discoveryUrl: "",
      clientId: "",
      scope: "",
      port,
    })

  const server = createServer(async (request, response) => {
    try {
      const requestUrl = new URL(
        request.url ?? "/",
        `http://${request.headers.host ?? `${host}:${port}`}`,
      )
      if (requestUrl.pathname === "/healthz") {
        if (request.method !== "GET" && request.method !== "HEAD") {
          response.setHeader("Allow", "GET, HEAD")
          writeJson(response, 405, { error: "method_not_allowed" })
          return
        }
        if (request.method === "HEAD") {
          response.writeHead(200)
          response.end()
          return
        }
        writeJson(response, 200, {
          service: "llmgw-okta-auth-proxy",
          status: "ready",
          fingerprint: resolvedFingerprint,
        })
        return
      }

      const upstreamPath = routeForPath(requestUrl.pathname)
      if (!upstreamPath) {
        writeJson(response, 404, { error: "route_not_found" })
        return
      }
      if (request.method !== "POST") {
        response.setHeader("Allow", "POST")
        writeJson(response, 405, { error: "method_not_allowed" })
        return
      }

      const body = await readRequestBody(request, maxRequestBytes)
      const upstreamUrl = new URL(
        `${upstreamBaseUrl.pathname.replace(/\/+$/, "")}${upstreamPath}`,
        upstreamBaseUrl,
      )
      upstreamUrl.search = requestUrl.search

      const send = async () => {
        const headers = copyRequestHeaders(request.headers)
        headers.set(
          "Authorization",
          `Bearer ${await credential.getToken({ interactive: false })}`,
        )
        return fetchImpl(upstreamUrl, {
          method: "POST",
          headers,
          body,
        })
      }

      let upstreamResponse = await send()
      if (upstreamResponse.status === 401) {
        await cancelBody(upstreamResponse)
        try {
          if (typeof credential.forceRefresh === "function") {
            await credential.forceRefresh({ interactive: false })
          } else {
            await credential.getToken({ interactive: false })
          }
        } catch (error) {
          if (error.code === AUTH_INTERACTIVE_REQUIRED) {
            writeJson(response, 401, {
              error: "login_required",
              message: error.message,
            })
            return
          }
          throw error
        }
        upstreamResponse = await send()
      }

      response.statusCode = upstreamResponse.status
      response.statusMessage = upstreamResponse.statusText
      copyResponseHeaders(upstreamResponse.headers, response)
      if (!upstreamResponse.body) {
        response.end()
        return
      }

      await pipeline(Readable.fromWeb(upstreamResponse.body), response)
    } catch (error) {
      if (error.code === "REQUEST_TOO_LARGE") {
        writeJson(response, 413, { error: "request_too_large" })
        return
      }
      if (error.code === AUTH_INTERACTIVE_REQUIRED) {
        writeJson(response, 401, {
          error: "login_required",
          message: error.message,
        })
        return
      }
      logger(`Okta auth proxy request failed: ${error.message}`)
      writeJson(response, 502, { error: "upstream_request_failed" })
    }
  })

  await new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off("listening", onListening)
      reject(error)
    }
    const onListening = () => {
      server.off("error", onError)
      resolve()
    }
    server.once("error", onError)
    server.once("listening", onListening)
    server.listen(port, host)
  })

  const address = server.address()
  const listeningPort =
    typeof address === "object" && address ? address.port : port
  return {
    server,
    url: `http://${host}:${listeningPort}`,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()))
      }),
  }
}

const isMain =
  process.argv[1] &&
  pathToFileURL(process.argv[1]).href === import.meta.url

if (isMain) {
  const port = readPositiveInteger(
    process.env.LLMGW_AUTH_PROXY_PORT || process.env.LLMGW_OKTA_PROXY_PORT,
    defaultPort,
    process.env.LLMGW_AUTH_PROXY_PORT
      ? "LLMGW_AUTH_PROXY_PORT"
      : "LLMGW_OKTA_PROXY_PORT",
  )
  const maxRequestBytes = readPositiveInteger(
    process.env.LLMGW_OKTA_PROXY_MAX_REQUEST_BYTES,
    defaultMaxRequestBytes,
    "LLMGW_OKTA_PROXY_MAX_REQUEST_BYTES",
  )

  try {
    const settings = readOktaClaudeSettings()
    const baseUrl = readGatewayBaseUrl()
    const fingerprint = authProxyFingerprint({
      baseUrl,
      discoveryUrl: settings.discoveryUrl,
      clientId: settings.clientId,
      scope: settings.scope,
      port,
    })
    const proxy = await startOktaAuthProxy({
      port,
      maxRequestBytes,
      baseUrl,
      fingerprint,
      credential: createOktaClaudeCredential({ settings }),
    })
    process.stderr.write(`Okta auth proxy listening on ${proxy.url}\n`)

    const shutdown = async () => {
      process.removeListener("SIGINT", shutdown)
      process.removeListener("SIGTERM", shutdown)
      await proxy.close()
    }
    process.on("SIGINT", shutdown)
    process.on("SIGTERM", shutdown)
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
