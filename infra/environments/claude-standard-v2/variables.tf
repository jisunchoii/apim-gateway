variable "prefix" {
  type        = string
  description = "Short workload prefix used in Azure resource names."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}$", var.prefix))
    error_message = "prefix must start with a lowercase letter and contain 2-13 lowercase letters, numbers, or hyphens."
  }
}

variable "env" {
  type        = string
  description = "Deployment environment token used in names and tags."

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.env))
    error_message = "env must contain 2-8 lowercase letters or numbers."
  }
}

variable "owner" {
  type        = string
  description = "Owner tag applied to all resources."
}

variable "cost_center" {
  type        = string
  description = "Cost center tag applied to all resources."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags merged into the required environment, workload, owner, and cost center tags."
}

variable "apim_location" {
  type        = string
  default     = "koreacentral"
  description = "Region for the Claude Standard v2 APIM and its outbound network."

  validation {
    condition     = lower(replace(replace(var.apim_location, " ", ""), "-", "")) == "koreacentral"
    error_message = "The Claude Standard v2 gateway must be deployed in Korea Central."
  }
}

variable "apim_publisher_name" {
  type        = string
  description = "Publisher display name for API Management."
}

variable "apim_publisher_email" {
  type        = string
  description = "Publisher email for API Management notifications."

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.apim_publisher_email))
    error_message = "apim_publisher_email must be a valid email address."
  }
}

variable "apim_sku" {
  type        = string
  default     = "StandardV2"
  description = "API Management SKU name. This Claude-specific root supports StandardV2 only."

  validation {
    condition     = var.apim_sku == "StandardV2"
    error_message = "apim_sku must be StandardV2 for the Claude Standard v2 environment."
  }
}

variable "apim_capacity" {
  type        = number
  default     = 1
  description = "Initial Standard v2 unit count."

  validation {
    condition     = var.apim_capacity >= 1 && var.apim_capacity <= 10 && floor(var.apim_capacity) == var.apim_capacity
    error_message = "apim_capacity must be a whole number from 1 to 10."
  }
}

variable "vnet_address_space" {
  type        = list(string)
  default     = ["10.82.0.0/24"]
  description = "Address space for the Claude gateway outbound VNet."

  validation {
    condition     = length(var.vnet_address_space) > 0 && alltrue([for prefix in var.vnet_address_space : can(cidrhost(prefix, 0))])
    error_message = "vnet_address_space must contain valid CIDR prefixes."
  }
}

variable "apim_subnet_address_prefixes" {
  type        = list(string)
  default     = ["10.82.0.0/27"]
  description = "Dedicated subnet prefixes for Standard v2 outbound VNet integration."

  validation {
    condition = length(var.apim_subnet_address_prefixes) > 0 && alltrue([
      for prefix in var.apim_subnet_address_prefixes :
      can(cidrhost(prefix, 0)) && try(tonumber(split("/", prefix)[1]) <= 27, false)
    ])
    error_message = "apim_subnet_address_prefixes must contain valid CIDR prefixes sized /27 or larger."
  }
}

variable "nat_idle_timeout_minutes" {
  type        = number
  default     = 10
  description = "StandardV2 NAT Gateway TCP idle timeout."

  validation {
    condition     = var.nat_idle_timeout_minutes >= 4 && var.nat_idle_timeout_minutes <= 120
    error_message = "nat_idle_timeout_minutes must be from 4 to 120."
  }
}

variable "oidc_provider" {
  type = object({
    openid_config_url = string
    audience          = string
    issuer            = string
    client_id         = string
    client_scope      = string
    required_scope    = string
    scope_claim       = string
    role_claim        = string
    required_role     = string
    user_label_claim  = string
  })
  description = "Existing Keycloak settings reused by the Claude gateway and terminal clients."

  validation {
    condition = (
      startswith(var.oidc_provider.openid_config_url, "https://") &&
      startswith(var.oidc_provider.issuer, "https://") &&
      trimspace(var.oidc_provider.audience) != "" &&
      trimspace(var.oidc_provider.client_id) != "" &&
      trimspace(var.oidc_provider.required_scope) != "" &&
      trimspace(var.oidc_provider.scope_claim) != "" &&
      trimspace(var.oidc_provider.role_claim) != "" &&
      trimspace(var.oidc_provider.required_role) != "" &&
      trimspace(var.oidc_provider.user_label_claim) != ""
    )
    error_message = "oidc_provider must use HTTPS endpoints and non-empty client, audience, scope, role, and user label values."
  }
}

variable "databricks_claude_gateway" {
  type = object({
    workspace_url = string
    models = object({
      opus   = string
      sonnet = string
      haiku  = string
      fable  = string
    })
  })
  description = "Existing Azure Databricks workspace and current Claude model defaults."

  validation {
    condition = (
      startswith(var.databricks_claude_gateway.workspace_url, "https://") &&
      startswith(var.databricks_claude_gateway.models.opus, "system.ai.claude-opus-") &&
      startswith(var.databricks_claude_gateway.models.sonnet, "system.ai.claude-sonnet-") &&
      startswith(var.databricks_claude_gateway.models.haiku, "system.ai.claude-haiku-") &&
      startswith(var.databricks_claude_gateway.models.fable, "system.ai.claude-fable-")
    )
    error_message = "databricks_claude_gateway must use an HTTPS workspace URL and system.ai Claude Opus, Sonnet, Haiku, and Fable model names."
  }
}

variable "user_tokens_per_minute" {
  type        = number
  default     = 0
  description = "Optional per-user, per-model token limit. Zero disables the limit."

  validation {
    condition     = var.user_tokens_per_minute >= 0 && floor(var.user_tokens_per_minute) == var.user_tokens_per_minute
    error_message = "user_tokens_per_minute must be a non-negative whole number."
  }
}

variable "log_retention_days" {
  type        = number
  default     = 90
  description = "Log Analytics and workspace-based Application Insights retention."

  validation {
    condition     = contains([30, 31, 60, 90, 120, 180, 270, 365, 550, 730], var.log_retention_days)
    error_message = "log_retention_days must be an Azure-supported Log Analytics retention value."
  }
}

variable "token_metric_namespace" {
  type        = string
  default     = "ClaudeGateway"
  description = "Application Insights custom metric namespace used by llm-emit-token-metric."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9._-]{0,63}$", var.token_metric_namespace))
    error_message = "token_metric_namespace must start with a letter and be at most 64 letters, numbers, dots, underscores, or hyphens."
  }
}

variable "model_pricing_dbu_per_million" {
  type = map(object({
    input        = number
    output       = number
    cached_input = number
  }))
  default     = {}
  description = "Estimated Databricks DBUs per million uncached input, output, and cached input tokens for each configured model."

  validation {
    condition = alltrue(flatten([
      for pricing in values(var.model_pricing_dbu_per_million) : [
        pricing.input >= 0,
        pricing.output >= 0,
        pricing.cached_input >= 0,
      ]
    ]))
    error_message = "All model_pricing_dbu_per_million values must be non-negative."
  }
}

variable "databricks_dbu_price_usd" {
  type        = number
  default     = 0
  description = "Estimated USD price per Azure Databricks Serverless Real-Time Inference DBU. Zero leaves USD cost unconfigured."

  validation {
    condition     = var.databricks_dbu_price_usd >= 0
    error_message = "databricks_dbu_price_usd must be non-negative."
  }
}

variable "trace_source" {
  type        = string
  default     = "claude-standard-v2"
  description = "Application Insights trace source for pseudonymous user/model correlation."
}

variable "workbook_display_name" {
  type        = string
  default     = "Claude Standard v2 Gateway"
  description = "Display name of the Claude gateway Azure Monitor workbook."
}

variable "catalog_outputs" {
  type = object({
    registry_template = string
    registry_html     = string
  })
  default = {
    registry_template = "docs/claude-standard-v2-registry.template.html"
    registry_html     = "docs/claude-standard-v2-registry.html"
  }
  description = "Repository-relative paths used to generate the Claude-only HTML registry after apply."
}
