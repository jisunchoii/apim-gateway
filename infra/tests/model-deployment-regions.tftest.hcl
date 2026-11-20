mock_provider "azurerm" {}
mock_provider "azapi" {}

mock_provider "random" {
  override_during = plan

  mock_resource "random_string" {
    defaults = {
      result = "test01"
    }
  }
}

override_resource {
  target          = azurerm_api_management.apim
  override_during = plan
  values = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-llmgw-test-eus2/providers/Microsoft.ApiManagement/service/apim-llmgw-test-eus2-test01"
    public_ip_addresses = ["192.0.2.42"]
  }
}

override_resource {
  target          = azurerm_log_analytics_workspace.law
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-llmgw-test-eus2/providers/Microsoft.OperationalInsights/workspaces/log-llmgw-test-eus2"
  }
}

variables {
  prefix               = "llmgw"
  env                  = "test"
  trace_source         = "llm-gateway-test"
  location             = "eastus2"
  owner                = "platform@example.com"
  cost_center          = "test"
  apim_publisher_name  = "Platform"
  apim_publisher_email = "platform@example.com"

  routed_models                   = null
  opencode_default_model          = null
  opencode_small_model            = null
  managed_foundry_account_enabled = null
  project_model_deployments       = {}

  oidc_provider = {
    openid_config_url = "https://id.example.com/.well-known/openid-configuration"
    audience          = "llm-gateway"
    role_claim        = "roles"
    required_role     = "invoke"
    user_label_claim  = "username"
  }

  model_deployments = {
    "gpt-4o-mini" = {
      model_name    = "gpt-4o-mini"
      model_format  = "OpenAI"
      model_version = "2024-07-18"
      sku_name      = "GlobalStandard"
      capacity      = 1
      location      = "westus3"
    }
  }
}

run "mixed_deployment_regions" {
  command = plan

  override_resource {
    target          = azurerm_cognitive_account.foundry["gateway"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-llmgw-test-eus2/providers/Microsoft.CognitiveServices/accounts/ais-llmgw-test-eus2-test01"
    }
  }

  override_resource {
    target          = azurerm_cognitive_account.foundry["region-westus3"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-llmgw-test-eus2/providers/Microsoft.CognitiveServices/accounts/ais-llmgw-test-r-westus3-test01"
    }
  }

  variables {
    model_deployments = {
      "gpt-4o" = {
        model_name    = "gpt-4o"
        model_format  = "OpenAI"
        model_version = "2024-08-06"
        sku_name      = "GlobalStandard"
        capacity      = 1
      }
      "gpt-4o-mini" = {
        model_name    = "gpt-4o-mini"
        model_format  = "OpenAI"
        model_version = "2024-07-18"
        sku_name      = "GlobalStandard"
        capacity      = 1
        location      = "westus3"
      }
      "gpt-4.1-mini" = {
        model_name    = "gpt-4.1-mini"
        model_format  = "OpenAI"
        model_version = "2025-04-14"
        sku_name      = "GlobalStandard"
        capacity      = 1
        location      = "westus3"
      }
    }
  }

  assert {
    condition = (
      length(azurerm_cognitive_account.foundry) == 2 &&
      azurerm_api_management.apim.location == "eastus2" &&
      azurerm_cognitive_account.foundry["gateway"].location == "eastus2" &&
      azurerm_cognitive_account.foundry["gateway"].name == "ais-llmgw-test-eus2-test01" &&
      azurerm_cognitive_account.foundry["region-westus3"].location == "westus3"
    )
    error_message = "The new region must have its own account without changing the existing gateway region or account."
  }

  assert {
    condition = (
      azurerm_cognitive_deployment.models["gpt-4o"].cognitive_account_id == azurerm_cognitive_account.foundry["gateway"].id &&
      azurerm_cognitive_deployment.models["gpt-4o-mini"].cognitive_account_id == azurerm_cognitive_account.foundry["region-westus3"].id &&
      azurerm_cognitive_deployment.models["gpt-4.1-mini"].cognitive_account_id == azurerm_cognitive_account.foundry["region-westus3"].id &&
      azurerm_api_management_backend.model["gpt-4o-mini"].url == "https://${azurerm_cognitive_account.foundry["region-westus3"].custom_subdomain_name}.openai.azure.com/openai/v1"
    )
    error_message = "Models and their APIM backends must use the selected accounts, sharing an account within a region."
  }

  assert {
    condition = (
      azurerm_role_assignment.apim_to_foundry["region-westus3"].scope == azurerm_cognitive_account.foundry["region-westus3"].id &&
      azurerm_role_assignment.apim_to_foundry["region-westus3"].role_definition_name == "Cognitive Services OpenAI User" &&
      toset(one(azurerm_cognitive_account.foundry["region-westus3"].network_acls).ip_rules) == toset(["192.0.2.42"])
    )
    error_message = "The regional account must grant inference access and allow the gateway's outbound IPs."
  }

  assert {
    condition = (
      strcontains(jsondecode(azurerm_application_insights_workbook.governance.data_json).items[0].content.json, "gpt-4o (eastus2)") &&
      strcontains(jsondecode(azurerm_application_insights_workbook.governance.data_json).items[0].content.json, "gpt-4o-mini (westus3)") &&
      strcontains(jsondecode(azurerm_application_insights_workbook.governance.data_json).items[3].content.query, "\"gpt-4o\", \"eastus2\"") &&
      strcontains(jsondecode(azurerm_application_insights_workbook.governance.data_json).items[3].content.query, "\"gpt-4o-mini\", \"westus3\", \"ais-llmgw-test-r-westus3-test01.openai.azure.com\"")
    )
    error_message = "Governance workbook must expose per-model deployment regions."
  }

  assert {
    condition = (
      alltrue([
        for item in jsondecode(azurerm_application_insights_workbook.governance.data_json).items :
        can(regex("by [^\\r\\n]*Model, BackendHost", item.content.query)) && !strcontains(item.content.query, "anyif(BackendHost")
        if try(contains(["operation-breakdown", "error-reasons", "throttling-errors"], item.name), false)
      ]) &&
      can(regex("let MinuteUsage\\s*=\\s*CurrentBackendRequests", one([
        for item in jsondecode(azurerm_application_insights_workbook.governance.data_json).items : item.content.query
        if try(item.name == "model-headroom", false)
      ])))
    )
    error_message = "Historical diagnostics must group by logged hosts, while headroom must use the configured host."
  }
}

run "regional_model_without_gateway_account" {
  command = plan

  assert {
    condition     = length(azurerm_cognitive_account.foundry) == 1 && output.foundry_account_name == null
    error_message = "A model deployed outside the gateway region must not create an unused account in the gateway region."
  }
}

run "retain_gateway_account_when_requested" {
  command = plan

  variables {
    managed_foundry_account_enabled = true
  }

  assert {
    condition     = output.foundry_account_name == "ais-llmgw-test-eus2-test01"
    error_message = "An explicitly enabled gateway account must be retained for deployments that otherwise use only other regions."
  }
}

run "reject_noncanonical_location" {
  command = plan

  variables {
    model_deployments = {
      "gpt-4o-mini" = {
        model_name    = "gpt-4o-mini"
        model_format  = "OpenAI"
        model_version = "2024-07-18"
        sku_name      = "GlobalStandard"
        capacity      = 1
        location      = "West US 3"
      }
    }
  }

  expect_failures = [var.model_deployments]
}
