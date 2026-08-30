import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const defaultHookScript = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "hooks",
  "session-start.js",
)

const defaultTimeoutSeconds = 300

/**
 * Build the Claude Code settings object that registers the Okta SessionStart hook.
 *
 * The hook runs in exec form (`command` + `args`) so Windows paths with spaces or
 * backslashes never pass through a shell. `command` is a real Node executable and
 * the hook script is a single argument, matching the cross-platform pattern Claude
 * Code documents for running bundled Node scripts.
 *
 * Any pre-existing settings are preserved; only `hooks.SessionStart` is replaced so
 * repeated launches never accumulate duplicate handlers.
 */
export const buildClaudeCodeSettings = ({
  nodePath = process.execPath,
  hookScript = defaultHookScript,
  timeoutSeconds = defaultTimeoutSeconds,
  existingSettings = {},
} = {}) => {
  const base =
    existingSettings && typeof existingSettings === "object"
      ? { ...existingSettings }
      : {}
  const hooks =
    base.hooks && typeof base.hooks === "object" ? { ...base.hooks } : {}
  hooks.SessionStart = [
    {
      hooks: [
        {
          type: "command",
          command: nodePath,
          args: [hookScript],
          timeout: timeoutSeconds,
        },
      ],
    },
  ]
  base.hooks = hooks
  return base
}

export const writeClaudeCodeSettings = async ({
  claudeDirectory,
  nodePath = process.execPath,
  hookScript = defaultHookScript,
  timeoutSeconds = defaultTimeoutSeconds,
} = {}) => {
  if (!claudeDirectory) {
    throw new Error(
      "claudeDirectory is required to write Claude Code settings.",
    )
  }
  const settingsPath = resolve(claudeDirectory, "settings.json")

  let existingSettings = {}
  try {
    const parsed = JSON.parse(await readFile(settingsPath, "utf8"))
    if (parsed && typeof parsed === "object") existingSettings = parsed
  } catch {
    // No readable settings file yet; start from an empty object.
  }

  const settings = buildClaudeCodeSettings({
    nodePath,
    hookScript,
    timeoutSeconds,
    existingSettings,
  })

  await mkdir(claudeDirectory, { recursive: true, mode: 0o700 })
  const temporaryPath = `${settingsPath}.${process.pid}.tmp`
  try {
    await writeFile(temporaryPath, `${JSON.stringify(settings, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    })
    await rename(temporaryPath, settingsPath)
  } finally {
    await rm(temporaryPath, { force: true })
  }

  return { settingsPath, settings, hookScript }
}
