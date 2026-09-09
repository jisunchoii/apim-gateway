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
import { createDeviceFlowLogger } from "./device-flow-logger.js"
import { createKeycloakDeviceCredential } from "./keycloak-device-auth.js"
import {
  readClaudeTerraformOutput,
  readClaudeTerraformStringOutput,
  readOpenCodeModelConfig,
  readTerraformStringOutput,
} from "./terraform-settings.js"

const responsesProviderId = "openai"
const projectProviderId = "foundry"
const claudeProviderId = "llmgw-claude"

const mergeModelDefinition = (defaults, configured = {}) => {
  const definition = {
    ...defaults,
    ...configured,
  }
  if (defaults.options || configured.options) {
    definition.options = {
      ...defaults.options,
      ...configured.options,
    }
  }
  if (defaults.variants || configured.variants) {
    definition.variants = {
      ...defaults.variants,
      ...configured.variants,
    }
  }
  return definition
}

const responsesModelDefinition = (model) => ({
  name: model,
  tool_call: true,
  options: {
    systemMessageMode: "system",
    reasoningEffort: "high",
    reasoningSummary: "auto",
    textVerbosity: "low",
    store: true,
    include: ["reasoning.encrypted_content"],
  },
})

const claudeModelDefinition = (model) => ({
  name: model,
  tool_call: true,
})

const normalizeBaseURL = (value) => value.replace(/\/+$/, "")

const toClaudeApiBaseURL = (value) => {
  const normalized = normalizeBaseURL(value)
  return normalized.endsWith("/v1") ? normalized : `${normalized}/v1`
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

export const KeycloakGateway = async () => {
  const readSetting = async (environmentName, terraformOutput, defaultValue = "") => {
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

  const parseModelList = (environmentName, configured) => {
    if (configured === undefined) return []

    let models
    try {
      models = configured.trim().startsWith("[")
        ? JSON.parse(configured)
        : configured.split(",")
    } catch (error) {
      throw new Error(
        `${environmentName} must be a JSON array or comma-delimited list.`,
        { cause: error },
      )
    }

    if (!Array.isArray(models)) {
      throw new Error(`${environmentName} must contain a model list.`)
    }

    return [
      ...new Set(
        models.map((model) => String(model).trim()).filter((model) => model),
      ),
    ]
  }

  const responsesModelsOverride =
    process.env.LLMGW_OPENCODE_RESPONSES_MODELS
  const chatModelsOverride = process.env.LLMGW_OPENCODE_CHAT_MODELS
  const hasExplicitMainConfiguration = [
    process.env.LLMGW_BASE_URL,
    responsesModelsOverride,
    chatModelsOverride,
  ].some((value) => value !== undefined)
  let modelConfig

  if (
    responsesModelsOverride !== undefined ||
    chatModelsOverride !== undefined
  ) {
    modelConfig = {
      responses_models: parseModelList(
        "LLMGW_OPENCODE_RESPONSES_MODELS",
        responsesModelsOverride,
      ),
      chat_models: parseModelList(
        "LLMGW_OPENCODE_CHAT_MODELS",
        chatModelsOverride,
      ),
      default_model: null,
      small_model: null,
    }
  } else {
    try {
      modelConfig = readOpenCodeModelConfig()
    } catch (error) {
      if (hasExplicitMainConfiguration) {
        throw new Error(
          "OpenCode model configuration is unavailable. Initialize the main infra state or set LLMGW_OPENCODE_RESPONSES_MODELS and LLMGW_OPENCODE_CHAT_MODELS.",
          { cause: error },
        )
      }
      modelConfig = {
        responses_models: [],
        chat_models: [],
        default_model: null,
        small_model: null,
      }
    }
  }

  const responsesModels = [
    ...new Set(modelConfig.responses_models ?? []),
  ].sort()
  const projectModels = [...new Set(modelConfig.chat_models ?? [])].sort()
  const duplicatedModels = responsesModels.filter((model) =>
    projectModels.includes(model),
  )

  if (duplicatedModels.length > 0) {
    throw new Error(
      `OpenCode models cannot use both providers: ${duplicatedModels.join(", ")}`,
    )
  }
  const claudeModelsOverride =
    process.env.LLMGW_OPENCODE_CLAUDE_MODELS
  const hasExplicitClaudeConfiguration = [
    process.env.LLMGW_CLAUDE_BASE_URL,
    claudeModelsOverride,
    process.env.LLMGW_OPENCODE_CLAUDE_DEFAULT_MODEL,
    process.env.LLMGW_OPENCODE_CLAUDE_SMALL_MODEL,
  ].some((value) => value !== undefined)
  let claudeConfig = null

  try {
    const modelsByAlias =
      claudeModelsOverride === undefined
        ? readClaudeTerraformOutput("claude_gateway_models")
        : null
    const claudeModels =
      claudeModelsOverride === undefined
        ? [
            ...new Set(
              Object.values(modelsByAlias ?? {})
                .map((model) => String(model).trim())
                .filter((model) => model),
            ),
          ].sort()
        : parseModelList(
            "LLMGW_OPENCODE_CLAUDE_MODELS",
            claudeModelsOverride,
          ).sort()

    if (claudeModels.length === 0) {
      throw new Error("Claude Gateway has no routed models.")
    }

    const configuredBaseURL =
      process.env.LLMGW_CLAUDE_BASE_URL?.trim() ||
      readClaudeTerraformStringOutput("claude_gateway_base_url")
    claudeConfig = {
      baseURL: toClaudeApiBaseURL(configuredBaseURL),
      models: claudeModels,
      default_model:
        process.env.LLMGW_OPENCODE_CLAUDE_DEFAULT_MODEL?.trim() ||
        modelsByAlias?.sonnet ||
        claudeModels[0],
      small_model:
        process.env.LLMGW_OPENCODE_CLAUDE_SMALL_MODEL?.trim() ||
        modelsByAlias?.haiku ||
        claudeModels[0],
    }
  } catch (error) {
    if (hasExplicitClaudeConfiguration) {
      throw new Error(
        "Claude OpenCode configuration is unavailable. Initialize the Claude Standard v2 infra state or set LLMGW_CLAUDE_BASE_URL and LLMGW_OPENCODE_CLAUDE_MODELS.",
        { cause: error },
      )
    }
  }

  const claudeModels = claudeConfig?.models ?? []
  const routedModelCount =
    responsesModels.length + projectModels.length + claudeModels.length
  if (routedModelCount === 0) {
    throw new Error("OpenCode has no routed models.")
  }
  const modelReferences = new Map([
    ...responsesModels.map((model) => [
      model,
      `${responsesProviderId}/${model}`,
    ]),
    ...projectModels.map((model) => [
      model,
      `${projectProviderId}/${model}`,
    ]),
    ...claudeModels.map((model) => [
      model,
      `${claudeProviderId}/${model}`,
    ]),
  ])
  const routedReferences = [...modelReferences.values()]
  const qualifyModel = (model) => {
    if (!model) return ""
    if (modelReferences.has(model)) return modelReferences.get(model)
    return routedReferences.includes(model) ? model : ""
  }
  const selectModel = (override, configured, defaults, fallback) => {
    const overrideReference = qualifyModel(override)
    if (override && !overrideReference) {
      throw new Error(`OpenCode model is not routed: ${override}`)
    }
    const configuredReference = qualifyModel(configured)
    if (
      configured &&
      !configuredReference &&
      [responsesProviderId, projectProviderId, claudeProviderId].some(
        (providerId) => configured.startsWith(`${providerId}/`),
      )
    ) {
      throw new Error(`OpenCode model is not routed: ${configured}`)
    }

    return (
      overrideReference ||
      configuredReference ||
      defaults.map(qualifyModel).find((model) => model) ||
      fallback
    )
  }
  const toModelDefinitions = (
    models,
    configuredModels = {},
    createDefaults = (model) => ({ name: model }),
  ) =>
    Object.fromEntries(
      models.map((model) => [
        model,
        mergeModelDefinition(createDefaults(model), configuredModels[model]),
      ]),
    )

  const baseURL =
    responsesModels.length + projectModels.length > 0
      ? normalizeBaseURL(
          await readSetting("LLMGW_BASE_URL", "gateway_base_url"),
        )
      : null
  const providerBaseURLs = new Map([
    ...(baseURL
      ? [
          [responsesProviderId, baseURL],
          [projectProviderId, baseURL],
        ]
      : []),
    ...(claudeConfig
      ? [[claudeProviderId, claudeConfig.baseURL]]
      : []),
  ])
  const discoveryUrl = await readSetting(
    "LLMGW_OIDC_DISCOVERY_URL",
    "oidc_openid_config_url",
  )
  const clientId = await readSetting(
    "LLMGW_OIDC_CLIENT_ID",
    "oidc_client_id",
    "llm-gateway-cli",
  )
  const scope = await readSetting(
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
  const openBrowser =
    process.env.LLMGW_OIDC_OPEN_BROWSER?.trim().toLowerCase() !== "false"
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
    logger: createDeviceFlowLogger({ openBrowser }),
  })

  return {
    config: async (config) => {
      const currentResponsesProvider =
        config.provider?.[responsesProviderId] ?? {}
      const currentProjectProvider =
        config.provider?.[projectProviderId] ?? {}
      const currentClaudeProvider =
        config.provider?.[claudeProviderId] ?? {}
      config.provider = {
        ...config.provider,
        ...(baseURL
          ? {
              [responsesProviderId]: {
                ...currentResponsesProvider,
                npm: "@ai-sdk/openai",
                name: "LLM Gateway",
                whitelist: responsesModels,
                options: {
                  ...currentResponsesProvider.options,
                  baseURL,
                  apiKey: "managed-by-keycloak-hook",
                  timeout: 300000,
                },
                models: {
                  ...currentResponsesProvider.models,
                  ...toModelDefinitions(
                    responsesModels,
                    currentResponsesProvider.models,
                    responsesModelDefinition,
                  ),
                },
              },
              [projectProviderId]: {
                ...currentProjectProvider,
                npm: "@ai-sdk/openai-compatible",
                name: "LLM Gateway Foundry Models",
                whitelist: projectModels,
                options: {
                  ...currentProjectProvider.options,
                  baseURL,
                  apiKey: "managed-by-keycloak-hook",
                  timeout: 300000,
                },
                models: {
                  ...currentProjectProvider.models,
                  ...toModelDefinitions(
                    projectModels,
                    currentProjectProvider.models,
                  ),
                },
              },
            }
          : {}),
        ...(claudeConfig
          ? {
              [claudeProviderId]: {
                ...currentClaudeProvider,
                npm: "@ai-sdk/anthropic",
                name: "LLM Gateway Claude",
                whitelist: claudeModels,
                options: {
                  ...currentClaudeProvider.options,
                  baseURL: claudeConfig.baseURL,
                  apiKey: "managed-by-keycloak-hook",
                  timeout: 300000,
                },
                models: {
                  ...currentClaudeProvider.models,
                  ...toModelDefinitions(
                    claudeModels,
                    currentClaudeProvider.models,
                    claudeModelDefinition,
                  ),
                },
              },
            }
          : {}),
      }
      config.model = selectModel(
        process.env.LLMGW_OPENCODE_DEFAULT_MODEL?.trim() ||
          process.env.LLMGW_OPENCODE_CLAUDE_DEFAULT_MODEL?.trim(),
        config.model,
        [modelConfig.default_model, claudeConfig?.default_model],
        routedReferences[0],
      )
      config.small_model = selectModel(
        process.env.LLMGW_OPENCODE_SMALL_MODEL?.trim() ||
          process.env.LLMGW_OPENCODE_CLAUDE_SMALL_MODEL?.trim(),
        config.small_model,
        [modelConfig.small_model, claudeConfig?.small_model],
        routedReferences[1] ?? routedReferences[0],
      )
    },
    "chat.params": async (input, output) => {
      if (
        input.model.providerID !== projectProviderId ||
        !projectModels.includes(input.model.id) ||
        !input.model.id.startsWith("gpt-")
      ) {
        return
      }

      delete output.options.reasoningEffort
      delete output.options.reasoningSummary
      delete output.options.textVerbosity
      delete output.options.include
    },
    "chat.headers": async (input, output) => {
      const requestBaseURL = String(
        input.provider.options.baseURL ?? "",
      )
      const expectedBaseURL = providerBaseURLs.get(input.model.providerID)
      if (
        !expectedBaseURL ||
        normalizeBaseURL(requestBaseURL) !== expectedBaseURL
      ) {
        return
      }

      output.headers.Authorization =
        "Bearer " + (await credential.getToken())
    },
  }
}
