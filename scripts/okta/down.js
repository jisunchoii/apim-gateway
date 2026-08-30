#!/usr/bin/env node

import { spawnSync } from "node:child_process"
import { readFile, rm } from "node:fs/promises"
import { createRequire } from "node:module"
import { homedir } from "node:os"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { resolveOpenCodexHome } from "../opencodex/configure-okta-gateway.js"

const require = createRequire(import.meta.url)
const openCodexPackagePath = require.resolve(
  "@bitkyc08/opencodex/package.json",
)
const openCodexLauncher = resolve(
  dirname(openCodexPackagePath),
  "bin",
  "ocx.mjs",
)

const wait = (milliseconds) =>
  new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds))

export const processExists = (pid, kill = process.kill) => {
  try {
    kill(pid, 0)
    return true
  } catch (error) {
    if (error.code === "ESRCH") return false
    if (error.code === "EPERM") return true
    throw error
  }
}

/**
 * Stop the persistent Okta auth proxy recorded by the SessionStart hook. Missing
 * state or an already-exited process is treated as success so `down` is idempotent.
 */
export const stopAuthProxy = async ({
  env = process.env,
  homeDirectory = homedir(),
  kill = (pid, signal) => process.kill(pid, signal),
  waitImpl = wait,
  waitTimeoutMs = 5_000,
  logger = (message) => process.stdout.write(`${message}\n`),
} = {}) => {
  const home = resolveOpenCodexHome({ env, homeDirectory })
  const statePath = resolve(home, "auth-proxy.json")

  let state
  try {
    state = JSON.parse(await readFile(statePath, "utf8"))
  } catch {
    logger("No running Okta auth proxy was recorded.")
    return { stopped: false }
  }

  const pid = Number(state?.pid)
  if (Number.isSafeInteger(pid) && pid > 0) {
    try {
      kill(pid, "SIGTERM")
      const deadline = Date.now() + waitTimeoutMs
      while (Date.now() < deadline && processExists(pid, kill)) {
        await waitImpl(50)
      }
      if (processExists(pid, kill)) {
        try {
          kill(pid, "SIGKILL")
        } catch (error) {
          if (error.code !== "ESRCH") throw error
        }
      }
      logger(`Stopped Okta auth proxy (pid ${pid}).`)
    } catch (error) {
      if (error.code !== "ESRCH") throw error
      logger(`Okta auth proxy (pid ${pid}) was not running.`)
    }
  }
  await rm(statePath, { force: true })
  return { stopped: true, pid }
}

/**
 * Stop the dedicated-profile OpenCodex server started on demand by `ocx claude`.
 */
export const stopOpenCodex = ({
  env = process.env,
  homeDirectory = homedir(),
  spawnImpl = spawnSync,
  logger = (message) => process.stdout.write(`${message}\n`),
} = {}) => {
  const home = resolveOpenCodexHome({ env, homeDirectory })
  const childEnv = {
    ...env,
    OPENCODEX_HOME: home,
    LLMGW_OPENCODEX_HOME: home,
  }
  const result = spawnImpl(process.execPath, [openCodexLauncher, "stop"], {
    env: childEnv,
    stdio: "inherit",
    windowsHide: true,
  })
  logger(
    result.status === 0
      ? "Stopped OpenCodex."
      : "OpenCodex reported no running server to stop.",
  )
  return result
}

export const main = async (deps = {}) => {
  await stopAuthProxy(deps)
  stopOpenCodex(deps)
}

const isMain =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isMain) {
  try {
    await main()
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
