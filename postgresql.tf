resource "random_password" "postgres" {
  length  = 32
  special = false
}

# --------------------------------------------------------------------------
# Private DNS for VNet-integrated Flexible Server. The zone name must end in
# .postgres.database.azure.com.
# --------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "postgresql" {
  name                = "${var.postgres_name}.private.postgres.database.azure.com"
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  name                 = "postgresql"
  private_dns_zone_id  = azurerm_private_dns_zone.postgresql.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}

# --------------------------------------------------------------------------
# PostgreSQL Flexible Server: delegated subnet, no public endpoint, zone-redundant HA.
# Shared by SonarQube Server and the Agent Orchestrator.
# --------------------------------------------------------------------------

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = var.postgres_name
  resource_group_name           = local.resource_group_name
  location                      = var.location
  version                       = "16"
  sku_name                      = var.postgres_sku
  storage_mb                    = var.postgres_storage_mb
  auto_grow_enabled             = true
  backup_retention_days         = var.postgres_backup_retention_days
  administrator_login           = var.db_username
  administrator_password        = random_password.postgres.result
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.postgresql.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgresql.id
  zone                          = "1"
  tags                          = var.tags

  # Zone-redundant HA needs a region with availability zones. Set
  # postgres_high_availability = false where the region has none.
  dynamic "high_availability" {
    for_each = var.postgres_high_availability ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }

  # A failover swaps the primary and standby zones. Ignoring both keeps the next plan from
  # trying to swap them back.
  lifecycle {
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgresql]
}

resource "azurerm_postgresql_flexible_server_database" "sonarqube" {
  name      = "sonarqube"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
