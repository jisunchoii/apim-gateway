#!/usr/bin/env node

import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { loadClientProfile, resolveGatewayBaseUrl } from "../oidc/client-profile.js"
import {
  buildOpenCodexConfig,
  readAuthProxyPort,
  readClaudeModelConfig,
  resolveOpenCodexHome,
} from "../opencodex/configure-okta-gateway.js"
import { validatePrerequisites } from "./claude.js"
import { readOktaClaudeSettings } from "./claude-credential.js"
import { authProxyFingerprint, openCodexFingerprint } from "./runtime-fingerprint.js"

const probeJson = async (url, { fetchImpl = globalThis.fetch, timeoutMs = 1_000 } = {}) => {
  try {
    const response = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs) })
    if (!response.ok) return null
    return await response.json()
  } catch {
    return null
  }
}

const check = async (name, work) => {
  try {
    return { name, ok: true, detail: await work() }
  } catch (error) {
    return { name, ok: false, detail: error.message }
  }
}

const tokenCacheMeta = async (cachePath) => {
  try {
    const stored = JSON.parse(await readFile(cachePath, "utf8"))
    const expiresAt = stored?.tokenSet?.expiresAt
    return {
      path: cachePath,
      present: true,
      hasRefreshToken: Boolean(stored?.tokenSet?.refreshToken),
      expiresAt: Number.isFinite(expiresAt)
        ? new Date(expiresAt).toISOString()
        : null,
    }
  } catch (error) {
    if (error.code === "ENOENT") {
      return { path: cachePath, present: false }
    }
    throw error
  }
}

export const collectDoctorReport = async ({
  env = process.env,
  homeDirectory = homedir(),
  fetchImpl = globalThis.fetch,
  validate = validatePrerequisites,
  loadProfile = loadClientProfile,
} = {}) => {
  const checks = []
  checks.push(
    await check("prerequisites", () => validate()),
  )
  checks.push(
    await check("gateway", () => resolveGatewayBaseUrl({ env })),
  )
  checks.push(
    await check("oidc", () => {
      const settings = readOktaClaudeSettings({ env, homeDirectory })
      return {
        discoveryHost: new URL(settings.discoveryUrl).host,
        clientIdConfigured: Boolean(settings.clientId),
        scope: settings.scope,
        cachePath: settings.cachePath,
      }
    }),
  )
  checks.push(
    await check("models", () => readClaudeModelConfig({ env })),
  )
  checks.push(
    await check("client_profile", () => {
      const profile = loadProfile({ env, optional: true })
      return profile
        ? { source: env.LLMGW_CLIENT_PROFILE?.trim() || "terraform", models: profile.models.length }
        : { source: "environment-only", models: null }
    }),
  )

  const oidcCheck = checks.find((item) => item.name === "oidc")
  const gatewayCheck = checks.find((item) => item.name === "gateway")
  if (oidcCheck.ok) {
    checks.push(
      await check("token_cache", () => tokenCacheMeta(oidcCheck.detail.cachePath)),
    )
  }

  const proxyPort = readAuthProxyPort(env)
  const openCodexPort = Number(env.LLMGW_OPENCODEX_PORT || 10100)
  const proxyHealth = await probeJson(`http://127.0.0.1:${proxyPort}/healthz`, {
    fetchImpl,
  })
  const settings = oidcCheck.ok
    ? readOktaClaudeSettings({ env, homeDirectory })
    : null
  let expectedProxyFingerprint
  if (settings && gatewayCheck.ok) {
    expectedProxyFingerprint = authProxyFingerprint({
      baseUrl: gatewayCheck.detail,
      discoveryUrl: settings.discoveryUrl,
      clientId: settings.clientId,
      scope: settings.scope,
      port: proxyPort,
    })
  }
  checks.push({
    name: "auth_proxy",
    ok: true,
    detail: proxyHealth
      ? {
          status: proxyHealth.status,
          fingerprint: proxyHealth.fingerprint,
          matches:
            expectedProxyFingerprint !== undefined &&
            proxyHealth.fingerprint === expectedProxyFingerprint,
        }
      : { status: "not_running" },
  })

  const openCodexHealth = await probeJson(
    `http://127.0.0.1:${openCodexPort}/health`,
    { fetchImpl },
  )
  let expectedOpenCodexFingerprint
  try {
    const modelConfig = readClaudeModelConfig({ env })
    const config = buildOpenCodexConfig({
      modelConfig,
      openCodexPort,
      authProxyPort: proxyPort,
    })
    expectedOpenCodexFingerprint = openCodexFingerprint({
      config,
      authProxyPort: proxyPort,
    })
  } catch {
    expectedOpenCodexFingerprint = undefined
  }
  let runningFingerprint
  try {
    const home = resolveOpenCodexHome({ env, homeDirectory })
    runningFingerprint = JSON.parse(
      await readFile(resolve(home, "opencodex-runtime.json"), "utf8"),
    ).fingerprint
  } catch {
    runningFingerprint = undefined
  }
  checks.push({
    name: "opencodex",
    ok: true,
    detail: openCodexHealth
      ? {
          status: "ready",
          fingerprint: runningFingerprint ?? null,
          matches:
            expectedOpenCodexFingerprint !== undefined &&
            runningFingerprint === expectedOpenCodexFingerprint,
        }
      : { status: "not_running" },
  })

  const required = new Set(["prerequisites", "gateway", "oidc", "models"])
  const ok = checks
    .filter((item) => required.has(item.name))
    .every((item) => item.ok)
  return { ok, checks }
}

export const formatDoctorReport = (report) =>
  [
    report.ok ? "Claude Code doctor: ok" : "Claude Code doctor: failed",
    ...report.checks.map((item) => {
      const detail =
        typeof item.detail === "string"
          ? item.detail
          : JSON.stringify(item.detail)
      return `${item.ok ? "ok" : "FAIL"}  ${item.name}: ${detail}`
    }),
  ].join("\n")

const isMain =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isMain) {
  try {
    const report = await collectDoctorReport()
    process.stdout.write(`${formatDoctorReport(report)}\n`)
    process.exitCode = report.ok ? 0 : 1
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
