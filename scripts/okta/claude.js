#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { readFile, writeFile } from "node:fs/promises"
import { createRequire } from "node:module"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { writeOpenCodexConfig } from "../opencodex/configure-okta-gateway.js"
import { writeClaudeCodeSettings } from "./claude-settings.js"
import { stopOpenCodex } from "./down.js"
import { openCodexFingerprint } from "./runtime-fingerprint.js"

const require = createRequire(import.meta.url)
const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..")
const openCodexPackagePath = require.resolve(
  "@bitkyc08/opencodex/package.json",
)
const projectPackage = JSON.parse(
  readFileSync(resolve(projectRoot, "package.json"), "utf8"),
)
const installedOpenCodexVersion = JSON.parse(
  readFileSync(openCodexPackagePath, "utf8"),
).version
const pinnedOpenCodexVersion =
  projectPackage.dependencies?.["@bitkyc08/opencodex"] ??
  projectPackage.devDependencies?.["@bitkyc08/opencodex"]
const openCodexLauncher = resolve(
  dirname(openCodexPackagePath),
  "bin",
  "ocx.mjs",
)

const readCommandVersion = (command) => {
  const executable =
    process.platform === "win32"
      ? process.env.ComSpec || "cmd.exe"
      : command
  const args =
    process.platform === "win32"
      ? ["/d", "/s", "/c", `${command} --version`]
      : ["--version"]
  const result = spawnSync(executable, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  })
  if (result.status !== 0) return null
  return `${result.stdout || ""}${result.stderr || ""}`.trim() || "unknown"
}

const waitForExit = (child) =>
  new Promise((resolvePromise, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      resolvePromise({ code, signal })
    })
  })

const wait = (milliseconds) =>
  new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds))

const probeOpenCodexReady = async (
  url,
  { fetchImpl = globalThis.fetch, timeoutMs = 1_000 } = {},
) => {
  try {
    const response = await fetchImpl(url, {
      signal: AbortSignal.timeout(timeoutMs),
    })
    return response.ok
  } catch {
    return false
  }
}

/**
 * Environment for `ocx claude`: point OpenCodex, its bundled client homes, and the
 * Claude Code config directory at the dedicated Okta profile so the user's normal
 * OpenCodex/Claude configuration is never touched.
 */
export const buildChildEnvironment = ({ setup, env = process.env }) => ({
  ...env,
  OPENCODEX_HOME: setup.configDirectory,
  CODEX_HOME: setup.codexDirectory,
  GROK_HOME: setup.grokDirectory,
  CLAUDE_CONFIG_DIR: setup.claudeDirectory,
  LLMGW_OPENCODEX_HOME: setup.configDirectory,
  LLMGW_OPENCODEX_PORT: String(setup.openCodexPort),
  LLMGW_AUTH_PROXY_PORT: String(setup.authProxyPort),
  LLMGW_OKTA_PROXY_PORT: String(setup.authProxyPort),
})

export const validatePrerequisites = ({
  nodeVersion = process.versions.node,
  claudeVersion = readCommandVersion("claude"),
  openCodexVersion = installedOpenCodexVersion,
  expectedOpenCodexVersion = pinnedOpenCodexVersion,
} = {}) => {
  if (Number(nodeVersion.split(".")[0]) < 20) {
    throw new Error("Claude Code Okta entry point requires Node.js 20 or later.")
  }
  if (!claudeVersion) {
    throw new Error(
      "Claude Code CLI is not installed or is unavailable on PATH.",
    )
  }
  if (
    !expectedOpenCodexVersion ||
    openCodexVersion !== expectedOpenCodexVersion
  ) {
    throw new Error(
      `Pinned OpenCodex ${expectedOpenCodexVersion || "(missing)"} is required; found ${openCodexVersion}.`,
    )
  }
  return { nodeVersion, claudeVersion, openCodexVersion }
}

/**
 * Ensure OpenCodex is listening before launching `ocx claude`. `ocx claude` starts
 * OpenCodex itself but only waits ~8 s for readiness (opencodex ensureProxyForClaude),
 * which a cold Bun start on this machine (~20 s) loses: the first launch then reports
 * "Proxy did not become healthy" and exits even though the detached process survives
 * and later launches reuse it. Pre-warm it here with a generous deadline so the very
 * first launch works. A proxy that is already healthy is reused without spawning.
 */
export const ensureOpenCodexReady = async ({
  setup,
  env = process.env,
  launcher = openCodexLauncher,
  fetchImpl = globalThis.fetch,
  spawnImpl = spawn,
  waitImpl = wait,
  logger = (message) => process.stderr.write(`${message}\n`),
  readyTimeoutMs = 60_000,
  stopImpl = stopOpenCodex,
  readFileImpl = readFile,
  writeFileImpl = writeFile,
} = {}) => {
  const port = setup.openCodexPort
  const healthUrl = `http://127.0.0.1:${port}/health`
  const fingerprint = openCodexFingerprint({
    config: setup.config,
    authProxyPort: setup.authProxyPort,
  })
  const statePath = setup.configDirectory
    ? resolve(setup.configDirectory, "opencodex-runtime.json")
    : null

  const probe = () => probeOpenCodexReady(healthUrl, { fetchImpl })
  if (await probe()) {
    let runningFingerprint
    if (statePath) {
      try {
        runningFingerprint = JSON.parse(
          await readFileImpl(statePath, "utf8"),
        ).fingerprint
      } catch {
        runningFingerprint = undefined
      }
    }
    if (runningFingerprint === fingerprint) {
      return { started: false, port }
    }
    logger(
      `OpenCodex on 127.0.0.1:${port} has a stale configuration; restarting.`,
    )
    stopImpl({ env, logger })
    const drainDeadline = Date.now() + readyTimeoutMs
    while (Date.now() < drainDeadline && (await probe())) {
      await waitImpl(250)
    }
  }

  logger(`Starting OpenCodex on 127.0.0.1:${port} (first launch may take ~20 s)...`)
  const child = spawnImpl(
    process.execPath,
    [launcher, "start", "--port", String(port)],
    {
      env: { ...env, OCX_SERVICE: "1" },
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    },
  )
  child.unref()

  const deadline = Date.now() + readyTimeoutMs
  while (Date.now() < deadline) {
    if (await probe()) {
      if (statePath) {
        await writeFileImpl(
          statePath,
          `${JSON.stringify({ pid: child.pid, port, fingerprint }, null, 2)}\n`,
          { encoding: "utf8", mode: 0o600 },
        )
      }
      logger(`OpenCodex ready on 127.0.0.1:${port} (pid ${child.pid}).`)
      return { started: true, port, pid: child.pid }
    }
    await waitImpl(500)
  }

  throw new Error(
    `OpenCodex did not become ready on 127.0.0.1:${port} within ${readyTimeoutMs} ms.`,
  )
}

/**
 * Ensure the dedicated OpenCodex profile and the Claude Code SessionStart hook exist.
 * Idempotent: safe to run before every launch.
 */
export const configure = async () => {
  const setup = await writeOpenCodexConfig()
  const { settingsPath } = await writeClaudeCodeSettings({
    claudeDirectory: setup.claudeDirectory,
  })
  return { setup, settingsPath }
}

export const main = async ({ extraArgs = [] } = {}) => {
  validatePrerequisites()
  const { setup } = await configure()
  const childEnvironment = buildChildEnvironment({ setup })
  await ensureOpenCodexReady({ setup, env: childEnvironment })

  const claudeChild = spawn(
    process.execPath,
    [openCodexLauncher, "claude", ...extraArgs],
    {
      env: childEnvironment,
      stdio: "inherit",
      windowsHide: true,
    },
  )
  const result = await waitForExit(claudeChild)
  process.exitCode = result.signal ? 1 : (result.code ?? 1)
}

const isMain =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isMain) {
  try {
    if (process.argv.slice(2).includes("--configure")) {
      validatePrerequisites()
      const { setup, settingsPath } = await configure()
      process.stdout.write(
        [
          `OpenCodex config: ${setup.configPath}`,
          `Claude Code settings: ${settingsPath}`,
          `Responses models: ${setup.modelConfig.responsesModels.join(", ") || "(none)"}`,
          `Chat models: ${setup.modelConfig.chatModels.join(", ") || "(none)"}`,
          `Default model: ${setup.modelConfig.defaultModel}`,
        ].join("\n") + "\n",
      )
    } else {
      await main({ extraArgs: process.argv.slice(2) })
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
