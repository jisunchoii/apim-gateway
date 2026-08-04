variable "prefix" {
  type        = string
  description = "Workload short name used in every resource name and in the workload tag."

  validation {
    condition = (
      length(var.prefix) >= 2 &&
      length(var.prefix) <= 16 &&
      can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.prefix))
    )
    error_message = "prefix must be 2-16 lowercase alphanumeric or hyphen characters, starting and ending with alphanumeric."
  }
}

variable "env" {
  type        = string
  description = "Environment short name used in resource names and the env tag."

  validation {
    condition = (
      length(var.env) >= 2 &&
      length(var.env) <= 8 &&
      can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.env))
    )
    error_message = "env must be 2-8 lowercase alphanumeric or hyphen characters, starting and ending with alphanumeric."
  }
}

variable "trace_source" {
  type        = string
  description = "Source name written by the APIM trace policy for Log Analytics correlation."

  validation {
    condition = (
      length(var.trace_source) >= 2 &&
      length(var.trace_source) <= 64 &&
      can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.trace_source))
    )
    error_message = "trace_source must be 2-64 lowercase alphanumeric or hyphen characters, starting and ending with alphanumeric."
  }
}

variable "location" {
  type        = string
  description = "Azure region for every resource. Verify model availability in this region first."

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "location must use the canonical lowercase Azure region name, such as eastus2."
  }
}

variable "owner" {
  type        = string
  description = "Value of the required owner tag."

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "cost_center" {
  type        = string
  description = "Value of the required costCenter tag."

  validation {
    condition     = length(trimspace(var.cost_center)) > 0
    error_message = "cost_center must not be empty."
  }
}

variable "apim_sku" {
  type        = string
  default     = "Premium_1"
  description = <<-EOT
    Classic API Management SKU as <tier>_<units>. Premium is the target tier: it is the only classic tier
    with autoscale, an SLA, availability zones, and 2,048 concurrent backend connections per unit
    (Developer caps at 1,024 with no SLA). Scaling units up or down later is non-disruptive, so start at
    Premium_1 and add units from load-test evidence rather than guessing.
    Do not use a v2 tier: v2 buffers only 2 MiB of payload and has no deterministic outbound IP, which the
    Foundry IP firewall in main.tf depends on.
  EOT

  validation {
    condition = (
      can(regex("^(Developer|Basic|Standard|Premium)_[0-9]+$", var.apim_sku)) &&
      try(tonumber(split("_", var.apim_sku)[1]), 0) >= 1
    )
    error_message = "apim_sku must be a classic tier as <tier>_<units>, with at least one unit."
  }
}

variable "apim_publisher_name" {
  type        = string
  description = "Publisher name shown on the API Management instance."
}

variable "apim_publisher_email" {
  type        = string
  description = "Publisher email for API Management notifications."
}

variable "managed_foundry_account_enabled" {
  type        = bool
  default     = null
  nullable    = true
  description = <<-EOT
    Controls the gateway-owned Foundry account used by model_deployments. Null creates the account
    automatically when model_deployments is non-empty. True keeps the account even when no managed
    deployments remain. False disables the account and requires model_deployments to be empty.
  EOT

  validation {
    condition = (
      var.managed_foundry_account_enabled != false ||
      length(var.model_deployments) == 0
    )
    error_message = "managed_foundry_account_enabled cannot be false when model_deployments is non-empty."
  }
}

variable "model_deployments" {
  type = map(object({
    model_name             = string
    model_format           = string
    model_version          = string
    version_upgrade_option = optional(string, "NoAutoUpgrade")
    sku_name               = string
    capacity               = number
    opencode_api           = optional(string, "responses")
  }))
  description = <<-EOT
    Model deployments keyed by deployment name. Keep the deployment name identical to the model name so
    clients send the real model id and the gateway stays an opaque passthrough. capacity is in thousands
    of tokens per minute for GlobalStandard, so 20000 == 20M TPM -- but apply fails if it exceeds the
    region's granted quota, which defaults to single-digit millions. Check with
    `az cognitiveservices usage list -l <region> -o table` and request an increase before raising it.
    opencode_api selects the OpenCode provider protocol and defaults to responses.
  EOT

  validation {
    condition = alltrue([
      for deployment in values(var.model_deployments) :
      contains(
        ["NoAutoUpgrade", "OnceCurrentVersionExpired", "OnceNewDefaultVersionAvailable"],
        deployment.version_upgrade_option
      )
    ])
    error_message = "version_upgrade_option must be NoAutoUpgrade, OnceCurrentVersionExpired, or OnceNewDefaultVersionAvailable."
  }

  validation {
    condition = alltrue([
      for deployment in values(var.model_deployments) :
      deployment.capacity > 0 && floor(deployment.capacity) == deployment.capacity
    ])
    error_message = "Every model deployment capacity must be a positive whole number."
  }

  validation {
    condition = alltrue([
      for deployment in values(var.model_deployments) :
      contains(["responses", "chat"], deployment.opencode_api)
    ])
    error_message = "Every managed model opencode_api must be responses or chat."
  }
}

variable "project_model_deployments" {
  type = map(object({
    project_resource_id = string
    capacity_tpm        = number
    opencode_api        = optional(string, "chat")
  }))
  default     = {}
  description = <<-EOT
    Existing model deployments exposed through a Foundry project endpoint. Terraform references the
    project but does not own or recreate the model deployment. The map key is the deployment name sent
    by clients. capacity_tpm is the deployment's effective token-per-minute limit used by governance
    dashboards; keep it aligned with the deployment owned by the source project. opencode_api selects
    the OpenCode provider protocol and defaults to chat.
  EOT

  validation {
    condition = (
      length(var.model_deployments) +
      length(var.project_model_deployments)
    ) > 0
    error_message = "At least one model must be configured in model_deployments or project_model_deployments."
  }

  validation {
    condition = alltrue([
      for deployment in values(var.project_model_deployments) :
      startswith(lower(deployment.project_resource_id), "/subscriptions/") &&
      strcontains(lower(deployment.project_resource_id), "/providers/microsoft.cognitiveservices/accounts/") &&
      strcontains(lower(deployment.project_resource_id), "/projects/")
    ])
    error_message = "Every project_model_deployments project_resource_id must be a Foundry project Azure resource ID."
  }

  validation {
    condition = alltrue([
      for deployment in values(var.project_model_deployments) :
      deployment.capacity_tpm > 0 && floor(deployment.capacity_tpm) == deployment.capacity_tpm
    ])
    error_message = "Every project model capacity_tpm must be a positive whole number."
  }

  validation {
    condition = alltrue([
      for deployment in values(var.project_model_deployments) :
      contains(["responses", "chat"], deployment.opencode_api)
    ])
    error_message = "Every project model opencode_api must be responses or chat."
  }

  validation {
    condition = length(setintersection(
      toset(keys(var.project_model_deployments)),
      toset(keys(var.model_deployments))
    )) == 0
    error_message = "A model name cannot appear in both model_deployments and project_model_deployments."
  }
}

variable "routed_models" {
  type        = set(string)
  default     = null
  description = <<-EOT
    Model backends referenced by the APIM policy. Defaults to every deployed backend. Keep this
    explicit when models are removed: first remove the model here and apply the policy change while
    its backend still exists, then remove the deployment entry in a second apply. This prevents Azure
    from rejecting backend deletion while the current policy still references it.
  EOT

  validation {
    condition     = var.routed_models == null || length(var.routed_models) > 0
    error_message = "routed_models must be null or contain at least one model."
  }
}

variable "opencode_default_model" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional routed model selected as the OpenCode default. Null selects the first routed model."
}

variable "opencode_small_model" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional routed model selected as the OpenCode small model. Null selects the second routed model."
}

variable "oidc_provider" {
  type = object({
    openid_config_url = string
    audience          = string
    issuer            = optional(string, "")
    client_id         = optional(string, "")
    client_scope      = optional(string, "openid llm-gateway")
    required_scope    = optional(string, "llm-gateway")
    scope_claim       = optional(string, "scope")
    role_claim        = string
    required_role     = string
    user_label_claim  = string
  })
  description = <<-EOT
    Keycloak settings for end-user access to the gateway. APIM validate-jwt reads signing keys and issuer
    metadata from openid_config_url. The terminal clients use a public client with Device Authorization Grant.

      openid_config_url  Discovery document, ending in /.well-known/openid-configuration.
      audience           The API audience mapper adds this value to the access token's `aud` claim.
      issuer             Optional extra check on the `iss` claim. Leave empty to accept whatever the
                         discovery document advertises. When set, it must match the token exactly.
      client_id          Public Keycloak client used by OpenCode and command-line token helpers.
      client_scope       Space-delimited scopes requested during device authorization.
      required_scope     Scope the access token must carry. Set to "" to skip scope authorization.
      scope_claim        Claim holding the scopes. Keycloak uses the standard `scope` claim.
      role_claim         Claim holding Gateway client roles. The supplied realm uses `llm_gateway_roles`.
      required_role      Role required to invoke the Gateway. Set to "" to skip role authorization.
      user_label_claim   Claim containing the username displayed in the Workbook.
  EOT

  validation {
    condition = (
      startswith(var.oidc_provider.openid_config_url, "https://") &&
      endswith(var.oidc_provider.openid_config_url, "/.well-known/openid-configuration")
    )
    error_message = "openid_config_url must be an HTTPS OIDC discovery document ending in /.well-known/openid-configuration."
  }

  validation {
    condition     = var.oidc_provider.client_scope != ""
    error_message = "client_scope must not be empty."
  }

  validation {
    condition     = var.oidc_provider.required_role == "" || var.oidc_provider.role_claim != ""
    error_message = "role_claim must not be empty when required_role is configured."
  }

  validation {
    condition     = trimspace(var.oidc_provider.user_label_claim) != ""
    error_message = "user_label_claim must not be empty."
  }
}

variable "user_tokens_per_minute" {
  type        = number
  default     = 0
  description = <<-EOT
    Per-user, per-model TPM ceiling. 0 (the default) omits the llm-token-limit policy entirely, which is
    the visibility-first posture: nobody is throttled. This is a blast-radius guard, not a budget --
    without it one runaway agent can consume the model's whole TPM and every other user gets 429 from the
    backend. Set it to roughly (model capacity * 1000) / expected concurrent users, then raise it: the
    number only has to be low enough to stop a loop, not low enough to shape normal usage. Read the real
    p99 out of the per-user KQL in the README before choosing.
  EOT

  validation {
    condition     = var.user_tokens_per_minute >= 0
    error_message = "user_tokens_per_minute must be 0 (disabled) or positive."
  }
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = <<-EOT
    Log Analytics retention. Token counts land in ApiManagementGatewayLlmLog and the per-user trace
    in ApiManagementGatewayLogs, so this also bounds how far back cost can be attributed.
  EOT

  validation {
    condition = (
      var.log_retention_days >= 30 &&
      var.log_retention_days <= 730 &&
      floor(var.log_retention_days) == var.log_retention_days
    )
    error_message = "log_retention_days must be a whole number from 30 to 730."
  }
}

variable "governance_workbook_display_name" {
  description = "Display name of the Azure Monitor workbook deployed with the gateway."
  type        = string
  default     = "LLM Gateway Governance"

  validation {
    condition     = length(trimspace(var.governance_workbook_display_name)) > 0
    error_message = "governance_workbook_display_name must not be empty."
  }
}

variable "model_pricing_usd_per_million" {
  description = "Optional model input/output prices in USD per 1M tokens for workbook cost estimates. Missing models are priced at zero."
  type = map(object({
    input  = number
    output = number
  }))
  default = {}

  validation {
    condition = alltrue([
      for pricing in values(var.model_pricing_usd_per_million) :
      pricing.input >= 0 && pricing.output >= 0
    ])
    error_message = "Model input and output prices must be zero or greater."
  }
}
