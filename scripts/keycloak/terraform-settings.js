import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..")
export const gatewayInfraDirectory = resolve(projectRoot, "infra")

const statePath = resolve(gatewayInfraDirectory, "terraform.tfstate")
const tfvarsPath = resolve(gatewayInfraDirectory, "terraform.tfvars")

const readLocalState = () => JSON.parse(readFileSync(statePath, "utf8"))

export const readTerraformOutput = (name) => {
  try {
    return JSON.parse(
      execFileSync(
        "terraform",
        [`-chdir=${gatewayInfraDirectory}`, "output", "-json", name],
        {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        },
      ),
    )
  } catch (terraformError) {
    try {
      const output = readLocalState().outputs?.[name]
      if (output) return output.value
    } catch {
      // Report the Terraform failure below when no local migration state exists.
    }

    throw new Error(`Could not read Terraform output: ${name}`, {
      cause: terraformError,
    })
  }
}

export const readTerraformStringOutput = (name) => {
  const value = readTerraformOutput(name)
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`Terraform output is not a non-empty string: ${name}`)
  }
  return value.trim()
}

const readTfvarsString = (name) => {
  try {
    const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    const match = readFileSync(tfvarsPath, "utf8").match(
      new RegExp(
        `^\\s*${escapedName}\\s*=\\s*"([^"]+)"\\s*(?:#.*)?$`,
        "m",
      ),
    )
    return match?.[1] ?? null
  } catch {
    return null
  }
}

export const readOpenCodeModelConfig = () => {
  try {
    return readTerraformOutput("opencode_model_config")
  } catch {
    const state = readLocalState()
    const routedModels = state.outputs?.routed_models?.value
    if (!Array.isArray(routedModels) || routedModels.length === 0) {
      throw new Error("Terraform state does not contain routed_models.")
    }

    const managedResource = state.resources?.find(
      (resource) =>
        resource.mode === "managed" &&
        resource.type === "azurerm_cognitive_deployment" &&
        resource.name === "models",
    )
    const managedModels = new Set(
      (managedResource?.instances ?? [])
        .map((instance) => instance.index_key)
        .filter((model) => routedModels.includes(model)),
    )
    const responsesModels = routedModels.filter((model) =>
      managedModels.has(model),
    )
    const chatModels = routedModels.filter(
      (model) => !managedModels.has(model),
    )

    return {
      responses_models: responsesModels,
      chat_models: chatModels,
      default_model: readTfvarsString("opencode_default_model"),
      small_model: readTfvarsString("opencode_small_model"),
    }
  }
}
