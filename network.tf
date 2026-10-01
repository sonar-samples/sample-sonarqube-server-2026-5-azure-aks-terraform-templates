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

  # Flexible Server adds this endpoint to its delegated subnet on its own. Declaring it keeps
  # the next plan from trying to strip it back out.
  service_endpoint {
    service = "Microsoft.Storage"
  }

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
  internal_exposure = var.sonarqube_exposure == "internal"

  # Static address for the SonarQube internal load balancer. Taken from the top of the subnet
  # because dynamic allocations (the private endpoint) fill from the bottom.
  sonarqube_internal_ip = cidrhost(var.private_subnet_cidr, -6)

  # The gateway's only backend, whichever exposure mode is selected.
  sonarqube_backend_ip = local.internal_exposure ? local.sonarqube_internal_ip : one(azurerm_public_ip.sonarqube_svc[*].ip_address)
}

# internal exposure only. The cluster identity creates the internal load balancer in the
# `private` subnet. On a bring-your-own VNet it needs Network Contributor there; without it the
# Service stays <pending> and the gateway backend never answers.
resource "azurerm_role_assignment" "aks_network" {
  count = local.internal_exposure ? 1 : 0

  scope                = azurerm_virtual_network.this.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

# gateway-restricted exposure only. Created in the AKS node resource group, where the cluster
# identity already holds Contributor, so AKS can attach it to its load balancer without any
# role assignment.
resource "azurerm_public_ip" "sonarqube_svc" {
  count = local.internal_exposure ? 0 : 1

  name                = "${var.cluster_name}-sonarqube-svc-pip"
  location            = var.location
  resource_group_name = azurerm_kubernetes_cluster.this.node_resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
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
