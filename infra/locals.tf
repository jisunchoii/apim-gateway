resource "random_string" "sfx" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  sfx = random_string.sfx.result

  # <type>-<workload>-<env>-<region>, plus the random suffix on globally-unique names.
  region_short_map = {
    koreacentral = "krc"
    koreasouth   = "krs"
    eastus       = "eus"
    eastus2      = "eus2"
    westeurope   = "weu"
  }
  region_key   = lower(var.location)
  region_token = replace(local.region_key, "/[^a-z0-9]/", "")
  region_short = lookup(local.region_short_map, local.region_key, substr(local.region_token, 0, 8))
  name_suffix  = "${var.prefix}-${var.env}-${local.region_short}"

  tags = {
    env        = var.env
    workload   = var.prefix
    owner      = var.owner
    costCenter = var.cost_center
  }

  apim_name         = "apim-${local.name_suffix}-${local.sfx}"
  foundry_name      = "ais-${local.name_suffix}-${local.sfx}"
  foundry_openai_v1 = "https://${local.foundry_name}.openai.azure.com/openai/v1"

  managed_foundry_account_enabled = coalesce(
    var.managed_foundry_account_enabled,
    length(var.model_deployments) > 0
  )
  managed_foundry_accounts = local.managed_foundry_account_enabled ? {
    gateway = true
  } : {}

  external_foundry_project_ids = toset([
    for deployment in values(var.project_model_deployments) :
    deployment.project_resource_id
  ])

  managed_model_targets = {
    for model_name, deployment in var.model_deployments :
    model_name => {
      backend_url   = local.foundry_openai_v1
      auth_resource = "https://cognitiveservices.azure.com"
      capacity_tpm  = deployment.capacity * 1000
      opencode_api  = deployment.opencode_api
    }
  }
  project_model_targets = {
    for model_name, deployment in var.project_model_deployments :
    model_name => {
      backend_url = "${trimsuffix(
        tostring(data.azapi_resource.external_foundry_project[deployment.project_resource_id].output.properties.endpoints["AI Foundry API"]),
        "/"
      )}/openai/v1"
      auth_resource = "https://ai.azure.com"
      capacity_tpm  = deployment.capacity_tpm
      opencode_api  = deployment.opencode_api
    }
  }
  model_targets      = merge(local.managed_model_targets, local.project_model_targets)
  deployed_models    = sort(keys(local.model_targets))
  model_capacity_tpm = { for model_name, target in local.model_targets : model_name => target.capacity_tpm }
  model_backend_ids = {
    for model_name in local.deployed_models :
    model_name => "model-${substr(sha1(model_name), 0, 16)}"
  }
  routed_models = var.routed_models != null ? sort(tolist(var.routed_models)) : local.deployed_models
  routed_model_backend_ids = {
    for model_name in local.routed_models :
    model_name => local.model_backend_ids[model_name]
    if contains(local.deployed_models, model_name)
  }
  routed_model_auth_resources = {
    for model_name in local.routed_models :
    model_name => local.model_targets[model_name].auth_resource
    if contains(local.deployed_models, model_name)
  }
  opencode_responses_models = [
    for model_name in local.routed_models :
    model_name if try(local.model_targets[model_name].opencode_api == "responses", false)
  ]
  opencode_chat_models = [
    for model_name in local.routed_models :
    model_name if try(local.model_targets[model_name].opencode_api == "chat", false)
  ]
  api_catalog_models = [
    for model_name in local.routed_models : {
      name             = model_name
      source           = contains(keys(var.model_deployments), model_name) ? "gateway-managed" : "external-project"
      backend_id       = local.model_backend_ids[model_name]
      backend_url      = local.model_targets[model_name].backend_url
      auth_resource    = local.model_targets[model_name].auth_resource
      api              = local.model_targets[model_name].opencode_api
      api_path         = local.model_targets[model_name].opencode_api == "responses" ? "/responses" : "/chat/completions"
      capacity_tpm     = local.model_targets[model_name].capacity_tpm
      model_name       = try(var.model_deployments[model_name].model_name, null)
      model_format     = try(var.model_deployments[model_name].model_format, null)
      model_version    = try(var.model_deployments[model_name].model_version, null)
      sku_name         = try(var.model_deployments[model_name].sku_name, null)
      capacity_units   = try(var.model_deployments[model_name].capacity, null)
      rai_policy_name  = try(var.model_deployments[model_name].rai_policy_name, null)
      project_resource = try(var.project_model_deployments[model_name].project_resource_id, null)
    }
  ]

  # Catch invalid policy routes before APIM accepts a configuration that can only fail at request time.
  undeployed_routed = setsubtract(local.routed_models, local.deployed_models)

  # Identifies our trace records in TraceRecords[].source when querying.
  trace_source = var.trace_source

  gateway_policy_parameters = {
    oidc_openid_config_url = var.oidc_provider.openid_config_url
    oidc_audience          = var.oidc_provider.audience
    oidc_issuer            = var.oidc_provider.issuer
    oidc_required_scope    = var.oidc_provider.required_scope
    oidc_scope_claim       = var.oidc_provider.scope_claim
    oidc_role_claim        = var.oidc_provider.role_claim
    oidc_required_role     = var.oidc_provider.required_role
    oidc_user_label_claim  = var.oidc_provider.user_label_claim
    user_tokens_per_minute = var.user_tokens_per_minute
    model_backend_ids      = local.routed_model_backend_ids
    model_auth_resources   = local.routed_model_auth_resources
    trace_source           = local.trace_source
  }
}
