#!/usr/bin/env node

import { mkdir, rename, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, resolve } from "node:path"
import { pathToFileURL } from "node:url"
import { loadClientProfile } from "../oidc/client-profile.js"
import { resolveOidcProvider } from "../oidc/providers.js"

const defaultOpenCodexPort = 10100
const defaultAuthProxyPort = 10101

const parsePositivePort = (value, fallback, name) => {
  if (value === undefined || value === "") return fallback
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 65535) {
    throw new Error(`${name} must be an integer from 1 to 65535.`)
  }
  return parsed
}

const parseModelList = (value, name) => {
  if (value === undefined) return undefined
  let models
  try {
    models = value.trim().startsWith("[")
      ? JSON.parse(value)
      : value.split(",")
  } catch (error) {
    throw new Error(`${name} must be a JSON array or comma-delimited list.`, {
      cause: error,
    })
  }
  if (!Array.isArray(models)) {
    throw new Error(`${name} must contain a model list.`)
  }
  return [
    ...new Set(
      models.map((model) => String(model).trim()).filter((model) => model),
    ),
  ].sort()
}

const uniqueModels = (names) => {
  const seen = new Set()
  const result = []
  for (const name of names) {
    const trimmed = String(name ?? "").trim()
    if (!trimmed || seen.has(trimmed)) continue
    seen.add(trimmed)
    result.push(trimmed)
  }
  return result
}

export const readModelCapabilities = (models) => {
  const capabilities = {}
  for (const model of models ?? []) {
    const name = String(model?.name ?? "").trim()
    if (!name) continue
    const capability = {}
    if (Number.isSafeInteger(model.context_window) && model.context_window > 0) {
      capability.contextWindow = model.context_window
    }
    if (typeof model.tools === "boolean") capability.tools = model.tools
    if (typeof model.streaming === "boolean") capability.streaming = model.streaming
    if (Object.keys(capability).length > 0) {
      capabilities[name] = capability
    }
  }
  return capabilities
}

const modelContextWindowsFor = (names, capabilities = {}) => {
  const windows = {}
  for (const name of names) {
    const window = capabilities[name]?.contextWindow
    if (Number.isSafeInteger(window) && window > 0) {
      windows[name] = window
    }
  }
  return Object.keys(windows).length > 0 ? windows : undefined
}

export const readAuthProxyPort = (
  env = process.env,
  fallback = defaultAuthProxyPort,
) => {
  const preferred = env.LLMGW_AUTH_PROXY_PORT
  const legacy = env.LLMGW_OKTA_PROXY_PORT
  const name =
    preferred !== undefined && preferred !== ""
      ? "LLMGW_AUTH_PROXY_PORT"
      : "LLMGW_OKTA_PROXY_PORT"
  return parsePositivePort(preferred || legacy, fallback, name)
}

const selectDefaultModel = (responsesModels, chatModels, configured) => {
  const allModels = new Set([...responsesModels, ...chatModels])
  if (configured) {
    if (!allModels.has(configured)) {
      throw new Error(`Claude Code default model is not routed: ${configured}`)
    }
    return configured
  }
  return responsesModels[0] ?? chatModels[0]
}

export const readClaudeModelConfig = ({
  env = process.env,
  profileReader = () => loadClientProfile({ env, optional: true }),
} = {}) => {
  const responsesOverride = parseModelList(
    env.LLMGW_CLAUDE_RESPONSES_MODELS,
    "LLMGW_CLAUDE_RESPONSES_MODELS",
  )
  const chatOverride = parseModelList(
    env.LLMGW_CLAUDE_CHAT_MODELS,
    "LLMGW_CLAUDE_CHAT_MODELS",
  )

  let responsesModels
  let chatModels
  let capabilities = {}
  if (responsesOverride !== undefined || chatOverride !== undefined) {
    responsesModels = uniqueModels(responsesOverride ?? [])
    chatModels = uniqueModels(chatOverride ?? [])
    try {
      capabilities = readModelCapabilities(profileReader()?.models)
    } catch {
      capabilities = {}
    }
  } else {
    const profile = profileReader()
    const models = Array.isArray(profile?.models) ? profile.models : null
    if (!models) {
      throw new Error(
        "Claude Code model catalog is unavailable. Set LLMGW_CLIENT_PROFILE or LLMGW_CLAUDE_RESPONSES_MODELS / LLMGW_CLAUDE_CHAT_MODELS.",
      )
    }
    responsesModels = uniqueModels(
      models
        .filter((model) => model.api === "responses")
        .map((model) => model.name),
    )
    chatModels = uniqueModels(
      models.filter((model) => model.api === "chat").map((model) => model.name),
    )
    capabilities = readModelCapabilities(models)
  }

  const duplicated = responsesModels.filter((model) =>
    chatModels.includes(model),
  )
  if (duplicated.length > 0) {
    throw new Error(
      `Claude Code models cannot use both APIM APIs: ${duplicated.join(", ")}`,
    )
  }
  if (responsesModels.length + chatModels.length === 0) {
    throw new Error("Claude Code has no routed APIM models.")
  }

  const defaultModel = selectDefaultModel(
    responsesModels,
    chatModels,
    env.LLMGW_CLAUDE_DEFAULT_MODEL?.trim(),
  )
  return { responsesModels, chatModels, defaultModel, capabilities }
}

const providerForModel = (model, modelConfig) =>
  modelConfig.responsesModels.includes(model)
    ? "apim-responses"
    : "apim-chat"

const routedModel = (model, modelConfig) =>
  `${providerForModel(model, modelConfig)}/${model}`

export const buildOpenCodexConfig = ({
  modelConfig,
  openCodexPort = defaultOpenCodexPort,
  authProxyPort = defaultAuthProxyPort,
} = {}) => {
  const proxyBaseUrl = `http://127.0.0.1:${authProxyPort}`
  const providers = {}

  if (modelConfig.responsesModels.length > 0) {
    const responsesWindows = modelContextWindowsFor(
      modelConfig.responsesModels,
      modelConfig.capabilities,
    )
    providers["apim-responses"] = {
      adapter: "openai-responses",
      baseUrl: proxyBaseUrl,
      responsesPath: "/v1/responses",
      authMode: "key",
      apiKey: "local-okta-auth-proxy",
      liveModels: false,
      models: modelConfig.responsesModels,
      selectedModels: modelConfig.responsesModels,
      defaultModel: modelConfig.responsesModels[0],
      allowPrivateNetwork: true,
      ...(responsesWindows ? { modelContextWindows: responsesWindows } : {}),
    }
  }

  if (modelConfig.chatModels.length > 0) {
    const chatWindows = modelContextWindowsFor(
      modelConfig.chatModels,
      modelConfig.capabilities,
    )
    providers["apim-chat"] = {
      adapter: "openai-chat",
      baseUrl: `${proxyBaseUrl}/v1`,
      authMode: "key",
      apiKey: "local-okta-auth-proxy",
      liveModels: false,
      models: modelConfig.chatModels,
      selectedModels: modelConfig.chatModels,
      defaultModel: modelConfig.chatModels[0],
      allowPrivateNetwork: true,
      ...(chatWindows ? { modelContextWindows: chatWindows } : {}),
    }
  }

  const defaultRoute = routedModel(modelConfig.defaultModel, modelConfig)
  const allRoutes = [
    ...modelConfig.responsesModels.map((model) =>
      routedModel(model, modelConfig),
    ),
    ...modelConfig.chatModels.map((model) => routedModel(model, modelConfig)),
  ]

  return {
    port: openCodexPort,
    hostname: "127.0.0.1",
    openaiProviderTierVersion: 2,
    clientIntegrations: {
      codex: false,
      grok: false,
    },
    providers,
    defaultProvider: providerForModel(modelConfig.defaultModel, modelConfig),
    modelPickerOrder: allRoutes,
    subagentModels: allRoutes.slice(0, 5),
    claudeCode: {
      enabled: true,
      nativePassthrough: false,
      authMode: "proxy",
      model: defaultRoute,
      smallFastModel: defaultRoute,
      tierModels: {
        opus: defaultRoute,
        sonnet: defaultRoute,
        haiku: defaultRoute,
        fable: defaultRoute,
      },
      injectAgents: false,
      autoContext: Object.values(modelConfig.capabilities ?? {}).some(
        (capability) =>
          Number.isSafeInteger(capability.contextWindow) &&
          capability.contextWindow > 200_000,
      ),
    },
    websockets: false,
  }
}

export const resolveOpenCodexHome = ({
  env = process.env,
  homeDirectory = homedir(),
} = {}) => {
  const provider = resolveOidcProvider({ env })
  return resolve(
    env.LLMGW_OPENCODEX_HOME?.trim() ||
      env.OPENCODEX_HOME?.trim() ||
      resolve(homeDirectory, ".llmgw", provider.profileHomeName),
  )
}

export const writeOpenCodexConfig = async ({
  env = process.env,
  homeDirectory = homedir(),
  modelConfig = readClaudeModelConfig({ env }),
} = {}) => {
  const openCodexPort = parsePositivePort(
    env.LLMGW_OPENCODEX_PORT,
    defaultOpenCodexPort,
    "LLMGW_OPENCODEX_PORT",
  )
  const authProxyPort = readAuthProxyPort(env, defaultAuthProxyPort)
  if (openCodexPort === authProxyPort) {
    throw new Error("OpenCodex and the Okta auth proxy must use different ports.")
  }

  const configDirectory = resolveOpenCodexHome({ env, homeDirectory })
  const codexDirectory = resolve(configDirectory, "codex")
  const grokDirectory = resolve(configDirectory, "grok")
  const claudeDirectory = resolve(configDirectory, "claude")
  const configPath = resolve(configDirectory, "config.json")
  const config = buildOpenCodexConfig({
    modelConfig,
    openCodexPort,
    authProxyPort,
  })

  await Promise.all(
    [
      dirname(configPath),
      codexDirectory,
      grokDirectory,
      claudeDirectory,
    ].map((directory) =>
      mkdir(directory, { recursive: true, mode: 0o700 }),
    ),
  )
  const temporaryPath = `${configPath}.${process.pid}.tmp`
  try {
    await writeFile(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    })
    await rename(temporaryPath, configPath)
  } finally {
    await rm(temporaryPath, { force: true })
  }

  return {
    config,
    configDirectory,
    configPath,
    codexDirectory,
    grokDirectory,
    claudeDirectory,
    openCodexPort,
    authProxyPort,
    modelConfig,
  }
}

const isMain =
  process.argv[1] &&
  pathToFileURL(process.argv[1]).href === import.meta.url

if (isMain) {
  try {
    const result = await writeOpenCodexConfig()
    const currentGateway = (() => {
      try {
        return (
          process.env.LLMGW_BASE_URL?.trim() ||
          loadClientProfile({ optional: true })?.gateway_base_url ||
          "environment-only"
        )
      } catch {
        return process.env.LLMGW_BASE_URL?.trim() || "environment-only"
      }
    })()
    process.stdout.write(
      [
        `OpenCodex config: ${result.configPath}`,
        `Gateway: ${currentGateway}`,
        `Responses models: ${result.modelConfig.responsesModels.join(", ") || "(none)"}`,
        `Chat models: ${result.modelConfig.chatModels.join(", ") || "(none)"}`,
        `Default model: ${result.modelConfig.defaultModel}`,
      ].join("\n") + "\n",
    )
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
