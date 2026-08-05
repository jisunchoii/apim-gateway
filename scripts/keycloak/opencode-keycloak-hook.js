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
import {
  readOpenCodeModelConfig,
  readTerraformStringOutput,
} from "./terraform-settings.js"

const responsesProviderId = "openai"
const projectProviderId = "foundry"
const gatewayProviderIds = new Set([responsesProviderId, projectProviderId])

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
      throw new Error(
        "OpenCode model configuration is unavailable. Initialize the main infra state or set LLMGW_OPENCODE_RESPONSES_MODELS and LLMGW_OPENCODE_CHAT_MODELS.",
        { cause: error },
      )
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
  if (responsesModels.length + projectModels.length === 0) {
    throw new Error("OpenCode has no routed models.")
  }

  const defaultModel =
    process.env.LLMGW_OPENCODE_DEFAULT_MODEL?.trim() ||
    modelConfig.default_model
  const smallModel =
    process.env.LLMGW_OPENCODE_SMALL_MODEL?.trim() ||
    modelConfig.small_model
  const modelReferences = new Map([
    ...responsesModels.map((model) => [
      model,
      `${responsesProviderId}/${model}`,
    ]),
    ...projectModels.map((model) => [
      model,
      `${projectProviderId}/${model}`,
    ]),
  ])
  const routedReferences = [...modelReferences.values()]
  const qualifyModel = (model) => {
    if (!model) return ""
    if (modelReferences.has(model)) return modelReferences.get(model)
    return routedReferences.includes(model) ? model : ""
  }
  const selectModel = (preferred, configured, fallback) => {
    const preferredReference = qualifyModel(preferred)
    if (preferred && !preferredReference) {
      throw new Error(`OpenCode model is not routed: ${preferred}`)
    }
    return preferredReference || qualifyModel(configured) || fallback
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

  const baseURL = (
    await readSetting("LLMGW_BASE_URL", "gateway_base_url")
  ).replace(/\/+$/, "")
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
  })

  return {
    config: async (config) => {
      const currentResponsesProvider =
        config.provider?.[responsesProviderId] ?? {}
      const currentProjectProvider =
        config.provider?.[projectProviderId] ?? {}
      config.provider = {
        ...config.provider,
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
      config.model = selectModel(
        defaultModel,
        config.model,
        routedReferences[0],
      )
      config.small_model = selectModel(
        smallModel,
        config.small_model,
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
      ).replace(/\/+$/, "")
      if (
        !gatewayProviderIds.has(input.model.providerID) ||
        requestBaseURL !== baseURL
      ) {
        return
      }

      output.headers.Authorization =
        "Bearer " + (await credential.getToken())
    },
  }
}
