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

  default_node_pool {
    name        = "system"
    vm_size     = var.system_vm_size
    node_count  = 2
    node_labels = { workload = "system" }

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

  # Required by azurerm 5.x. "Manual" keeps the node pools declared here authoritative.
  # Node auto-provisioning would manage them instead, and cannot set workload_runtime
  # on the sandbox pool.
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }
}

# Pod sandboxing pool. os_sku MUST be AzureLinux — no other OS SKU supports it.
# min_count = 0 permits scale-down only when nothing schedulable needs the pool. With
# fixed runtime replicas those pods are long-lived, so expect this pool to scale up at
# deploy time and stay provisioned. True scale-to-zero needs validated chart autoscaling.
resource "azurerm_kubernetes_cluster_node_pool" "sandbox" {
  count = var.enable_agentic && var.enable_pod_sandboxing ? 1 : 0

  name                  = "sandbox"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.sandbox_vm_size
  os_sku                = "AzureLinux"
  workload_runtime      = "KataVmIsolation"

  # Runtime ephemeral storage comes off the OS disk on VM series with no local temp
  # disk. The Hunter Agent alone requests 15Gi.
  os_disk_size_gb = 128

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = var.sandbox_max_nodes
  node_count           = 0

  node_labels = { workload = "sandbox" }
  node_taints = ["workload=sandbox:NoSchedule"]
  tags        = var.tags

  upgrade_settings {
    drain_timeout_in_minutes      = 0
    max_surge                     = "10%"
    node_soak_duration_in_minutes = 0
  }

  # node_count is the initial size only. Once the cluster autoscaler owns the pool it
  # moves the count to meet demand, so leaving it in the diff makes every later apply
  # scale the pool back to zero and evict the running agent runtimes.
  lifecycle {
    ignore_changes = [node_count]
  }
}
