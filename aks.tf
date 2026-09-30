resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = coalesce(var.kubernetes_version, data.azurerm_kubernetes_service_versions.current.latest_version)
  tags                = var.tags

  # Sized for the agentic path: with enable_agentic = true this pool carries SonarQube Server,
  # Vortex, the Orchestrator, the egress proxy AND both agent runtimes. Chart requests total
  # roughly 3.8 vCPU and 20.6Gi of memory, and the Hunter Agent alone requests 8Gi — so a 16Gi
  # node cannot hold it alongside Vortex and the Server. Two D8s_v5 nodes leave real headroom.
  default_node_pool {
    name        = "system"
    vm_size     = var.system_vm_size
    node_count  = var.system_node_count
    node_labels = { workload = "system" }

    # Runtime ephemeral storage comes off the OS disk on VM series with no local temp disk.
    # The Hunter Agent requests 15Gi and the Remediation Agent 10Gi.
    os_disk_size_gb = 128

    # Azure applies these defaults server-side. Declaring them keeps a repeat plan
    # clean instead of showing a perpetual "remove upgrade_settings" diff.
    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
  }

  # Required by azurerm 5.x. "Manual" keeps the node pool declared here authoritative;
  # node auto-provisioning would manage it instead.
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }
}
