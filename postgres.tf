resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = var.postgres_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.location
  version                       = "16"
  sku_name                      = "GP_Standard_D2ds_v5"
  storage_mb                    = 32768
  administrator_login           = "sonarqube"
  administrator_password        = random_password.postgres.result
  public_network_access_enabled = true
  tags                          = var.tags

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "sonarqube" {
  name      = "sonarqube"
  server_id = azurerm_postgresql_flexible_server.this.id
}

# Open the firewall to the cluster's outbound address and nothing else.
locals {
  egress_ip_id = tolist(azurerm_kubernetes_cluster.this.network_profile[0].load_balancer_profile[0].effective_outbound_ips)[0]
}

data "azurerm_public_ip" "aks_egress" {
  name                = reverse(split("/", local.egress_ip_id))[0]
  resource_group_name = azurerm_kubernetes_cluster.this.node_resource_group
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "aks" {
  name             = "aks-egress"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = data.azurerm_public_ip.aks_egress.ip_address
  end_ip_address   = data.azurerm_public_ip.aks_egress.ip_address
}
