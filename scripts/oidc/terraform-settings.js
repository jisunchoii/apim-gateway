import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..")
export const gatewayInfraDirectory = resolve(projectRoot, "infra")

const statePath = resolve(gatewayInfraDirectory, "terraform.tfstate")

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
      // Report the Terraform failure below when no local state is available.
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

export const readApiCatalogManifest = () => {
  const manifest = readTerraformOutput("api_catalog_manifest")
  if (
    manifest?.schema_version !== 1 ||
    !manifest.gateway ||
    !Array.isArray(manifest.models)
  ) {
    throw new Error("Terraform api_catalog_manifest has an invalid shape.")
  }
  return manifest
}
