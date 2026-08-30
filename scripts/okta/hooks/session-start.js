#!/usr/bin/env node

import { spawn } from "node:child_process"
import { closeSync, openSync } from "node:fs"
import { mkdir, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { resolveGatewayBaseUrl } from "../../oidc/client-profile.js"
import { createOktaClaudeCredential, readOktaClaudeSettings } from "../claude-credential.js"
import { stopAuthProxy } from "../down.js"
import { authProxyFingerprint } from "../runtime-fingerprint.js"
import {
  readAuthProxyPort,
  resolveOpenCodexHome,
} from "../../opencodex/configure-okta-gateway.js"

const authProxyScript = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "okta-auth-proxy.js",
)

const authProxyService = "llmgw-okta-auth-proxy"

const wait = (milliseconds) =>
  new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds))

const readProxyHealth = async (
  url,
  { fetchImpl = globalThis.fetch, timeoutMs = 1_000 } = {},
) => {
  try {
    const response = await fetchImpl(url, {
      signal: AbortSignal.timeout(timeoutMs),
    })
    if (!response.ok) return null
    return await response.json()
  } catch {
    return null
  }
}

/**
 * Claude Code delivers the SessionStart event as JSON on stdin. Drain it so the
 * writer is never left blocked on a full pipe; the payload itself is not needed.
 */
export const drainStdin = async (stream = process.stdin) => {
  if (!stream || stream.isTTY) return
  try {
    for await (const _chunk of stream) {
      // Intentionally ignored.
    }
  } catch {
    // A closed or absent stdin is not an error for this hook.
  }
}

/**
 * Acquire (or silently refresh) the Okta access token for Claude Code. On the first
 * run this performs the interactive Device Authorization flow; afterwards it reuses
 * the cached refresh token without any prompt. All diagnostics stay on stderr so the
 * hook never writes to stdout, which Claude Code would inject into the session.
 */
export const ensureOktaAuth = async ({
  createCredential = createOktaClaudeCredential,
} = {}) => {
  await createCredential().getToken()
}

/**
 * Ensure the loopback Okta APIM auth proxy is running. Reuses an already-healthy
 * proxy, otherwise starts a detached, persistent process that outlives this hook so
 * later Claude Code sessions start instantly. Records the pid for `down`.
 */
const resolveExpectedFingerprint = ({ env, homeDirectory, port, expectedFingerprint }) => {
  if (expectedFingerprint) return expectedFingerprint
  const settings = readOktaClaudeSettings({ env, homeDirectory })
  return authProxyFingerprint({
    baseUrl: resolveGatewayBaseUrl({ env }),
    discoveryUrl: settings.discoveryUrl,
    clientId: settings.clientId,
    scope: settings.scope,
    port,
  })
}

export const ensureAuthProxy = async ({
  env = process.env,
  homeDirectory = homedir(),
  fetchImpl = globalThis.fetch,
  spawnImpl = spawn,
  waitImpl = wait,
  logger = (message) => process.stderr.write(`${message}\n`),
  readyTimeoutMs = 10_000,
  expectedFingerprint,
  stopProxy = stopAuthProxy,
} = {}) => {
  const port = readAuthProxyPort(env)
  const healthUrl = `http://127.0.0.1:${port}/healthz`
  const fingerprint = resolveExpectedFingerprint({
    env,
    homeDirectory,
    port,
    expectedFingerprint,
  })

  const existing = await readProxyHealth(healthUrl, { fetchImpl })
  if (existing) {
    if (existing.service !== authProxyService) {
      throw new Error(`Port ${port} is already used by another service.`)
    }
    if (existing.fingerprint === fingerprint) {
      return { started: false, port }
    }
    logger(
      `Okta auth proxy on 127.0.0.1:${port} has a stale configuration; restarting.`,
    )
    await stopProxy({ env, homeDirectory, logger, waitImpl })
    const drainDeadline = Date.now() + readyTimeoutMs
    while (Date.now() < drainDeadline) {
      const leftover = await readProxyHealth(healthUrl, { fetchImpl })
      if (!leftover) break
      await waitImpl(250)
    }
  }

  const home = resolveOpenCodexHome({ env, homeDirectory })
  await mkdir(home, { recursive: true, mode: 0o700 })
  const logPath = resolve(home, "auth-proxy.log")
  const logFd = openSync(logPath, "a")
  let child
  try {
    child = spawnImpl(process.execPath, [authProxyScript], {
      env,
      detached: true,
      stdio: ["ignore", logFd, logFd],
      windowsHide: true,
    })
  } finally {
    try {
      closeSync(logFd)
    } catch {
      // The child owns a duplicated descriptor; closing ours may already be done.
    }
  }
  child.unref()

  const deadline = Date.now() + readyTimeoutMs
  while (Date.now() < deadline) {
    const health = await readProxyHealth(healthUrl, { fetchImpl })
    if (health && health.service === authProxyService && health.status === "ready") {
      const statePath = resolve(home, "auth-proxy.json")
      await writeFile(
        statePath,
        `${JSON.stringify({ pid: child.pid, port, fingerprint }, null, 2)}\n`,
        { encoding: "utf8", mode: 0o600 },
      )
      logger(`Okta auth proxy ready on 127.0.0.1:${port} (pid ${child.pid}).`)
      return { started: true, port, pid: child.pid }
    }
    await waitImpl(250)
  }

  throw new Error(
    `Okta auth proxy did not become ready within ${readyTimeoutMs} ms. See ${logPath}.`,
  )
}

export const runSessionStartHook = async (deps = {}) => {
  await drainStdin(deps.stdin)
  await ensureOktaAuth(deps)
  await ensureAuthProxy(deps)
}

const isMain =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isMain) {
  try {
    await runSessionStartHook()
    process.exitCode = 0
  } catch (error) {
    process.stderr.write(`Okta SessionStart hook failed: ${error.message}\n`)
    process.exitCode = 1
  }
}
