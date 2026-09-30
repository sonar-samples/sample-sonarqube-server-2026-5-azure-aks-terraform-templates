# --------------------------------------------------------------------------
# Log Analytics workspace for Container insights (the AKS oms_agent add-on in aks.tf).
# Container logs from the Server, Orchestrator, Vortex, egress proxy and both runtimes land here.
# --------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.cluster_name}-logs"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}
