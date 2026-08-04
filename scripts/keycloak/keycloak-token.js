#!/usr/bin/env node

import { createHash } from "node:crypto"
import { execFileSync } from "node:child_process"
import {
  chmod,
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, resolve } from "node:path"
import { createKeycloakDeviceCredential } from "./keycloak-device-auth.js"
import { readTerraformStringOutput } from "./terraform-settings.js"

const readSetting = (environmentName, terraformOutput, defaultValue = "") => {
  const configured = process.env[environmentName]?.trim()
  if (configured) return configured

  try {
    return readTerraformStringOutput(terraformOutput)
  } catch {
    // Environment-only client installations do not need local Terraform state.
  }

  if (defaultValue) return defaultValue

  throw new Error(
    `${environmentName} is not set and no configured Terraform output is available.`,
  )
}

const hardenTokenFile = async (path) => {
  if (process.platform === "win32") {
    const identity = execFileSync("whoami", [], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim()
    execFileSync(
      "icacls",
      [path, "/inheritance:r", "/grant:r", `${identity}:(F)`],
      { stdio: "ignore" },
    )
    return
  }

  await chmod(path, 0o600)
}

const main = async () => {
  const discoveryUrl = readSetting(
    "LLMGW_OIDC_DISCOVERY_URL",
    "oidc_openid_config_url",
  )
  const clientId = readSetting(
    "LLMGW_OIDC_CLIENT_ID",
    "oidc_client_id",
    "llm-gateway-cli",
  )
  const scope = readSetting(
    "LLMGW_OIDC_SCOPE",
    "oidc_client_scope",
    "openid llm-gateway",
  )
  const cachePath =
    process.env.LLMGW_OIDC_CACHE_PATH?.trim() ||
    resolve(homedir(), ".llmgw", "keycloak-token.json")
  const cacheKey = createHash("sha256")
    .update(`${discoveryUrl}\n${clientId}\n${scope}`)
    .digest("hex")

  const tokenStore = {
    load: async () => {
      try {
        const stored = JSON.parse(await readFile(cachePath, "utf8"))
        return stored.cacheKey === cacheKey ? stored.tokenSet : undefined
      } catch (error) {
        if (error.code === "ENOENT") return undefined
        throw new Error(`Could not read Keycloak token cache: ${cachePath}`, {
          cause: error,
        })
      }
    },
    save: async (tokenSet) => {
      await mkdir(dirname(cachePath), { recursive: true, mode: 0o700 })
      const temporaryPath = `${cachePath}.${process.pid}.tmp`
      try {
        await writeFile(
          temporaryPath,
          JSON.stringify({ cacheKey, tokenSet }),
          { encoding: "utf8", mode: 0o600 },
        )
        await hardenTokenFile(temporaryPath)
        await rename(temporaryPath, cachePath)
        await hardenTokenFile(cachePath)
      } finally {
        await rm(temporaryPath, { force: true })
      }
    },
    clear: async () => {
      await rm(cachePath, { force: true })
    },
  }

  const credential = createKeycloakDeviceCredential({
    discoveryUrl,
    clientId,
    scope,
    tokenStore,
    logger: (message) => process.stderr.write(`${message}\n`),
  })

  process.stdout.write(`${await credential.getToken()}\n`)
}

try {
  await main()
} catch (error) {
  process.stderr.write(`${error.message}\n`)
  process.exitCode = 1
}
