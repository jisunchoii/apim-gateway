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
import { dirname } from "node:path"

const hardenFile = async (path, platform, execFile) => {
  if (platform === "win32") {
    const identity = execFile("whoami", [], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim()
    execFile(
      "icacls",
      [path, "/inheritance:r", "/grant:r", `${identity}:(F)`],
      { stdio: "ignore" },
    )
    return
  }

  await chmod(path, 0o600)
}

export const createTokenCacheKey = ({ discoveryUrl, clientId, scope }) =>
  createHash("sha256")
    .update(`${discoveryUrl}\n${clientId}\n${scope}`)
    .digest("hex")

export const createFileTokenStore = ({
  cachePath,
  cacheKey,
  providerName = "OIDC provider",
  platform = process.platform,
  execFile = execFileSync,
}) => ({
  load: async () => {
    try {
      const stored = JSON.parse(await readFile(cachePath, "utf8"))
      return stored.cacheKey === cacheKey ? stored.tokenSet : undefined
    } catch (error) {
      if (error.code === "ENOENT") return undefined
      throw new Error(
        `Could not read ${providerName} token cache: ${cachePath}`,
        { cause: error },
      )
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
      await hardenFile(temporaryPath, platform, execFile)
      await rename(temporaryPath, cachePath)
      await hardenFile(cachePath, platform, execFile)
    } finally {
      await rm(temporaryPath, { force: true })
    }
  },
  clear: async () => {
    await rm(cachePath, { force: true })
  },
})
