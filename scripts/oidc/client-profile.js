import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { gatewayInfraDirectory } from "./terraform-settings.js"

const normalizeBaseUrl = (value) => String(value ?? "").replace(/\/+$/, "")

export const clientProfileSchemaVersion = 1

export const validateClientProfile = (profile) => {
  if (
    profile?.schema_version !== clientProfileSchemaVersion ||
    typeof profile.gateway_base_url !== "string" ||
    !profile.gateway_base_url.trim() ||
    typeof profile.oidc !== "object" ||
    profile.oidc === null ||
    typeof profile.oidc.discovery_url !== "string" ||
    !profile.oidc.discovery_url.trim() ||
    typeof profile.oidc.client_id !== "string" ||
    !profile.oidc.client_id.trim() ||
    !Array.isArray(profile.models)
  ) {
    throw new Error("client_profile has an invalid shape.")
  }
  return profile
}

const readTerraformClientProfile = () =>
  validateClientProfile(
    JSON.parse(
      execFileSync(
        "terraform",
        [`-chdir=${gatewayInfraDirectory}`, "output", "-json", "client_profile"],
        {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        },
      ),
    ),
  )

export const loadClientProfile = ({
  env = process.env,
  readFile = readFileSync,
  terraformReader,
  optional = true,
} = {}) => {
  const profilePath = env.LLMGW_CLIENT_PROFILE?.trim()
  if (profilePath) {
    return validateClientProfile(JSON.parse(readFile(profilePath, "utf8")))
  }

  try {
    if (terraformReader) {
      return validateClientProfile(terraformReader("client_profile"))
    }
    return readTerraformClientProfile()
  } catch (error) {
    if (optional) return null
    throw new Error(
      "Client profile is unavailable. Set LLMGW_CLIENT_PROFILE or the LLMGW_* environment variables.",
      { cause: error },
    )
  }
}

export const resolveGatewayBaseUrl = ({
  env = process.env,
  profile,
  loadProfile = loadClientProfile,
} = {}) => {
  const configured = env.LLMGW_BASE_URL?.trim()
  if (configured) return normalizeBaseUrl(configured)

  const loaded =
    profile !== undefined ? profile : loadProfile({ env, optional: true })
  const fromProfile = loaded?.gateway_base_url?.trim()
  if (fromProfile) return normalizeBaseUrl(fromProfile)

  throw new Error(
    "LLMGW_BASE_URL is not set and client_profile is unavailable.",
  )
}
