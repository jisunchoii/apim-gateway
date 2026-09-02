resource "azurerm_resource_group" "claude" {
  name     = local.resource_group_name
  location = var.apim_location
  tags     = local.tags
}

resource "azurerm_network_security_group" "apim" {
  name                = "nsg-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.claude.name
  location            = azurerm_resource_group.claude.location
  tags                = local.tags

  security_rule {
    name                       = "AllowAzureActiveDirectory"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureActiveDirectory"
  }

  security_rule {
    name                       = "AllowAzureCloudHttps"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "AllowAzureSql"
    priority                   = 140
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Sql"
  }

  security_rule {
    name                       = "AllowInternetHttps"
    priority                   = 150
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "DenyOtherOutbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "claude" {
  name                = "vnet-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.claude.name
  location            = azurerm_resource_group.claude.location
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "apim" {
  name                 = "snet-apim-outbound"
  resource_group_name  = azurerm_resource_group.claude.name
  virtual_network_name = azurerm_virtual_network.claude.name
  address_prefixes     = var.apim_subnet_address_prefixes

  delegation {
    name = "apim-v2-outbound"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

resource "azapi_resource" "nat_public_ip" {
  type      = "Microsoft.Network/publicIPAddresses@2025-01-01"
  name      = "pip-${local.name_suffix}"
  parent_id = azurerm_resource_group.claude.id
  location  = azurerm_resource_group.claude.location
  tags      = local.tags

  body = {
    sku = {
      name = "StandardV2"
      tier = "Regional"
    }
    properties = {
      publicIPAllocationMethod = "Static"
      publicIPAddressVersion   = "IPv4"
    }
  }

  response_export_values = ["properties.ipAddress"]
}

resource "azapi_resource" "nat_gateway" {
  type      = "Microsoft.Network/natGateways@2025-01-01"
  name      = "ng-${local.name_suffix}"
  parent_id = azurerm_resource_group.claude.id
  location  = azurerm_resource_group.claude.location
  tags      = local.tags

  body = {
    sku = {
      name = "StandardV2"
    }
    properties = {
      idleTimeoutInMinutes = var.nat_idle_timeout_minutes
      publicIpAddresses = [
        {
          id = azapi_resource.nat_public_ip.id
        }
      ]
    }
  }
}

resource "azurerm_subnet_nat_gateway_association" "apim" {
  subnet_id      = azurerm_subnet.apim.id
  nat_gateway_id = azapi_resource.nat_gateway.id
}
