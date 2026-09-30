# --------------------------------------------------------------------------
# Virtual network
#
# Four subnets share the VNet:
#   aks        - node IPs only. Pods take overlay addresses (pod_cidr), not VNet addresses.
#   appgw      - Application Gateway v2. Must hold nothing else.
#   postgresql - delegated to Flexible Server for private VNet access.
#   private    - the SonarQube internal load balancer and the blob private endpoint.
# --------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  location            = var.location
  resource_group_name = local.resource_group_name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

resource "azurerm_subnet" "appgw" {
  name                 = "appgw"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.appgw_subnet_cidr]
}

resource "azurerm_subnet" "postgresql" {
  name                 = "postgresql"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.postgresql_subnet_cidr]

  delegation {
    name = "postgresql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private" {
  name                 = "private"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_subnet_cidr]
}

locals {
  # Static address for the SonarQube internal load balancer. Taken from the top of the subnet
  # because dynamic allocations (the private endpoint) fill from the bottom.
  sonarqube_internal_ip = cidrhost(var.private_subnet_cidr, -6)
}

# The cluster identity creates the internal load balancer in the `private` subnet and joins
# nodes to `aks`. On a bring-your-own VNet it needs Network Contributor there; without it the
# Service stays <pending> and the gateway backend never answers.
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_virtual_network.this.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

# --------------------------------------------------------------------------
# Application Gateway public IP
# --------------------------------------------------------------------------

resource "azurerm_public_ip" "appgw" {
  name                = "${var.cluster_name}-appgw-pip"
  location            = var.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}
