resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

locals {
  kubernetes_version = coalesce(var.kubernetes_version, data.azurerm_kubernetes_service_versions.current.latest_version)

  # Azure applies these defaults server-side. Declaring them keeps a repeat plan clean instead of
  # showing a perpetual "remove upgrade_settings" diff.
  upgrade_settings = {
    drain_timeout_in_minutes      = 0
    max_surge                     = "10%"
    node_soak_duration_in_minutes = 0
  }
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = local.kubernetes_version
  tags                = var.tags

  role_based_access_control_enabled = true

  # System pool: Kubernetes add-ons only. only_critical_addons_enabled taints it
  # CriticalAddonsOnly, so SonarQube and the agentic workloads never land here.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    node_count                   = var.system_node_count
    vnet_subnet_id               = azurerm_subnet.aks.id
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systemtmp"
    node_labels                  = { workload = "system" }

    upgrade_settings {
      drain_timeout_in_minutes      = local.upgrade_settings.drain_timeout_in_minutes
      max_surge                     = local.upgrade_settings.max_surge
      node_soak_duration_in_minutes = local.upgrade_settings.node_soak_duration_in_minutes
    }
  }

  # Azure CNI overlay on the VNet: nodes take VNet addresses, pods take pod_cidr addresses.
  # Cilium is the network policy engine. Without one, AKS accepts NetworkPolicy objects and
  # enforces none of them, which silently disables the chart's runtime and egress-proxy policies.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = cidrhost(var.service_cidr, 10)
  }

  # Required by azurerm 5.x. "Manual" keeps the node pools declared here authoritative;
  # node auto-provisioning would manage them instead.
  node_provisioning_profile {
    mode = "Manual"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  identity {
    type = "SystemAssigned"
  }
}

# SonarQube Server pool. Tainted so only the Server (which carries the matching toleration in
# sonarqube-values.yaml) schedules here.
resource "azurerm_kubernetes_cluster_node_pool" "sonarqube" {
  name                  = "sonarqube"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.sonarqube_vm_size
  node_count            = 1
  vnet_subnet_id        = azurerm_subnet.aks.id
  orchestrator_version  = local.kubernetes_version
  os_disk_size_gb       = 128
  node_labels           = { workload = "sonarqube" }
  node_taints           = ["workload=sonarqube:NoSchedule"]
  tags                  = var.tags

  upgrade_settings {
    drain_timeout_in_minutes      = local.upgrade_settings.drain_timeout_in_minutes
    max_surge                     = local.upgrade_settings.max_surge
    node_soak_duration_in_minutes = local.upgrade_settings.node_soak_duration_in_minutes
  }
}

# Agentic pool: Vortex, the Orchestrator, the egress proxy, the key-derivation hook and both agent
# runtimes. Tainted so the runtimes, which execute LLM-directed work against customer code, never
# share a node with SonarQube Server. Created only with enable_agentic = true.
#
# Chart requests for these workloads total roughly 3.3 vCPU and 16.5Gi at one runtime replica
# each, and the Hunter Agent alone requests 8Gi. Two D8s_v5 nodes also let the two egress-proxy
# replicas land on separate nodes.
resource "azurerm_kubernetes_cluster_node_pool" "agentic" {
  count = var.enable_agentic ? 1 : 0

  name                  = "agentic"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.agentic_vm_size
  node_count            = var.agentic_node_count
  vnet_subnet_id        = azurerm_subnet.aks.id
  orchestrator_version  = local.kubernetes_version
  node_labels           = { workload = "agentic" }
  node_taints           = ["workload=agentic:NoSchedule"]
  tags                  = var.tags

  # Runtime ephemeral storage comes off the OS disk on VM series with no local temp disk.
  # The Hunter Agent requests 15Gi and the Remediation Agent 10Gi.
  os_disk_size_gb = 128

  upgrade_settings {
    drain_timeout_in_minutes      = local.upgrade_settings.drain_timeout_in_minutes
    max_surge                     = local.upgrade_settings.max_surge
    node_soak_duration_in_minutes = local.upgrade_settings.node_soak_duration_in_minutes
  }
}
