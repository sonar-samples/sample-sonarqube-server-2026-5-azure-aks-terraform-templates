# Offline plan matrix. `terraform validate` does not evaluate locals, and Terraform evaluates
# both branches of every conditional, so each on/off combination has to reach a real plan.
# Mocked providers keep this runnable without an Azure subscription:
#
#   terraform init -backend=false && terraform test

mock_provider "azurerm" {
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks"
      kube_config = [{
        host                   = "https://aks.example.test:443"
        client_certificate     = "Y2VydA=="
        client_key             = "a2V5"
        cluster_ca_certificate = "Y2E="
        username               = "u"
        password               = "p"
      }]
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/acmesqagentic01"
    }
  }
  mock_data "azurerm_kubernetes_service_versions" {
    defaults = {
      latest_version = "1.35.0"
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "acme" {}
mock_provider "tls" {}
mock_provider "random" {}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  sonarqube_chart_version = "2026.5.1000"
  domain_name             = "example.com"
  dns_resource_group_name = "dns"
  acme_email              = "ops@example.com"
  storage_account_name    = "acmesqagentic01"
}

run "default_server_only" {
  command = plan

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.agentic) == 0
    error_message = "The agentic pool must not exist with enable_agentic = false."
  }
  assert {
    condition     = output.sonarqube_url == "https://sonarqube.example.com"
    error_message = "sonarqube_url must be the public HTTPS hostname."
  }
  assert {
    condition     = length(azurerm_private_endpoint.blob) == 0
    error_message = "No storage should be created without the agentic components."
  }
}

run "agentic_blob" {
  command = plan
  variables {
    enable_agentic = true
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.agentic) == 1
    error_message = "The agentic pool must exist with enable_agentic = true."
  }
  assert {
    condition     = length(azurerm_private_endpoint.blob) == 1 && azurerm_storage_account.agentic[0].public_network_access == "Disabled"
    error_message = "The blob account must be private and reached through its private endpoint."
  }
  assert {
    condition     = contains(local.egress_domains, "acmesqagentic01.blob.core.windows.net")
    error_message = "The blob host must be on the egress allowlist."
  }
  assert {
    condition     = local.agentic.agentEgressProxy.nodeSelector.workload == "agentic" && local.agentic.hunterAgent.nodeSelector.workload == "agentic"
    error_message = "Every agentic component must be pinned to the agentic pool."
  }
}

run "agentic_files" {
  command = plan
  variables {
    enable_agentic  = true
    storage_backend = "azurefiles"
  }

  assert {
    condition     = length(azurerm_storage_account.agentic) == 0 && length(kubernetes_persistent_volume_claim_v1.jobs) == 1
    error_message = "azurefiles must create PVCs and no blob account."
  }
}

run "agentic_blob_no_ha_encrypted" {
  command = plan
  variables {
    enable_agentic             = true
    postgres_high_availability = false
    enable_settings_encryption = true
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this.high_availability) == 0
    error_message = "HA must be omitted when postgres_high_availability = false."
  }
}

run "server_only_files_backend_ignored" {
  command = plan
  variables {
    storage_backend = "azurefiles"
  }

  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.jobs) == 0
    error_message = "No shares should be created without the agentic components."
  }
}
