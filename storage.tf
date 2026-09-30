resource "kubernetes_namespace_v1" "sonarqube" {
  metadata {
    name = "sonarqube"
  }
}

locals {
  ns = kubernetes_namespace_v1.sonarqube.metadata[0].name

  use_files = var.enable_agentic && var.storage_backend == "azurefiles"
  use_blob  = var.enable_agentic && var.storage_backend == "azureblob"

  # Two stores either way: agent job artifacts and Vortex analyzer context have opposite
  # retention lifecycles, so they never share a policy.
  jobs_store   = "agent-jobs"
  vortex_store = "vortex-context"

  # Filesystem backend only.
  jobs_claim      = local.jobs_store
  vortex_claim    = local.vortex_store
  jobs_base_dir   = "/agentic-storage"
  vortex_base_dir = "/vortex-context"

  # Object backend only. The runtime fetches presigned URLs over HTTPS, so this host must be
  # reachable through the egress proxy.
  blob_host = local.use_blob ? "${var.storage_account_name}.blob.core.windows.net" : ""
}

# ---------------------------------------------------------------------------
# Azure Blob Storage  (storage_backend = "azureblob")
# ---------------------------------------------------------------------------
#
# AzureObjectStore mints native SAS presigned URLs, so the runtime receives a locator scoped to
# one object and one verb and never mounts a volume or holds a credential.

resource "azurerm_storage_account" "agentic" {
  count = local.use_blob ? 1 : 0

  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = var.storage_replication_type
  min_tls_version          = "TLS1_2"
  tags                     = var.tags

  # Reachable only through the private endpoint below.
  public_network_access           = "Disabled"
  allow_nested_items_to_be_public = false

  # Must stay enabled. The object-store library authenticates to Azure by connection string only
  # and signs its SAS locators with the account key. An Azure Policy that forces shared key
  # access off breaks every agentic storage call.
  shared_access_key_enabled = true

  # Caught at plan time. Without this the empty name reaches the Azure API and fails
  # late with an opaque naming error, after the cluster has already been built.
  lifecycle {
    precondition {
      condition     = var.storage_account_name != ""
      error_message = "storage_account_name is required when storage_backend is azureblob. Use 3-24 lowercase alphanumerics, globally unique across Azure."
    }
  }
}

# Private endpoint and private DNS. The account hostname stays <account>.blob.core.windows.net;
# inside the VNet it resolves through privatelink.blob.core.windows.net to a private address.
# The egress proxy therefore still matches the runtimes' SAS requests by hostname, and its
# NetworkPolicy must keep private ranges reachable: do NOT add RFC1918 CIDRs to
# agentEgressProxy.networkPolicy.egressExcludeCidrs.
resource "azurerm_private_dns_zone" "blob" {
  count = local.use_blob ? 1 : 0

  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count = local.use_blob ? 1 : 0

  name                 = "blob"
  private_dns_zone_id  = azurerm_private_dns_zone.blob[0].id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_private_endpoint" "blob" {
  count = local.use_blob ? 1 : 0

  name                = "${var.storage_account_name}-blob"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private.id
  tags                = var.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.agentic[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob[0].id]
  }
}

resource "azurerm_storage_container" "jobs" {
  count = local.use_blob ? 1 : 0

  name               = local.jobs_store
  storage_account_id = azurerm_storage_account.agentic[0].id
}

resource "azurerm_storage_container" "vortex" {
  count = local.use_blob ? 1 : 0

  name               = local.vortex_store
  storage_account_id = azurerm_storage_account.agentic[0].id
}

# Connection-string authentication is the only option the object-store library offers for Azure,
# so the account key necessarily lives in a secret. Only the Orchestrator, Vortex and SonarQube
# Server read it — never the runtimes, which hold locators only.
#
# Two key names because the components read different property prefixes: the Orchestrator uses
# sonar.agentic.orchestrator.storage.*, while Vortex and SonarQube Server use
# sonar.agentic.storage.*.
resource "kubernetes_secret_v1" "azure_storage" {
  count = local.use_blob ? 1 : 0

  metadata {
    name      = "agentic-storage-azure"
    namespace = local.ns
  }
  data = {
    SONAR_AGENTIC_ORCHESTRATOR_STORAGE_AZURE_CONNECTION_STRING = azurerm_storage_account.agentic[0].primary_connection_string
    SONAR_AGENTIC_STORAGE_AZURE_CONNECTION_STRING              = azurerm_storage_account.agentic[0].primary_connection_string
  }
}

# The Orchestrator and Vortex are Spring Boot services, so relaxed binding maps
# SONAR_..._CONNECTION_STRING onto azure.connection-string and the env vars above bind.
# SonarQube Server is not: it maps SONAR_X_Y to sonar.x.y and can never produce the
# hyphen in `connection-string`, so that env var silently never binds and the server
# builds a BlobServiceClient with no connection string ("Invalid connection string").
# sonarSecretProperties merges a secret into sonar.properties via the concat-properties
# init container - the only way to pass a hyphenated property holding a secret value
# without exposing it in a ConfigMap.
resource "kubernetes_secret_v1" "azure_storage_props" {
  count = local.use_blob ? 1 : 0

  metadata {
    name      = "agentic-storage-azure-props"
    namespace = local.ns
  }
  data = {
    "secret.properties" = "sonar.agentic.storage.azure.connection-string=${azurerm_storage_account.agentic[0].primary_connection_string}\n"
  }
}

# ---------------------------------------------------------------------------
# Azure Files  (storage_backend = "azurefiles")
# ---------------------------------------------------------------------------
#
# The built-in azurefile-csi class sets no uid, gid or file_mode, so an SMB mount lands
# root-owned and the agentic containers (uid 900, 1000, 10001) cannot write to it.
#
# On a filesystem backend the mount permissions ARE the isolation boundary between untrusted
# runtimes — the library does not enforce it with signed URLs. The 0777 defaults are a lab
# setting; set share_gid and 0770 modes with a matching pod fsGroup for anything else.
resource "kubernetes_storage_class_v1" "agentic_files" {
  count = local.use_files ? 1 : 0

  metadata {
    name = "sonarqube-agentic-files"
  }
  storage_provisioner    = "file.csi.azure.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  # networkEndpointType has the CSI driver create each share's storage account with a private
  # endpoint in the cluster VNet instead of a public one.
  parameters = {
    skuName             = "Standard_LRS"
    networkEndpointType = "privateEndpoint"
  }

  mount_options = [
    "dir_mode=${var.share_dir_mode}",
    "file_mode=${var.share_file_mode}",
    "uid=0",
    "gid=${var.share_gid}",
    "mfsymlinks",
    "cache=strict",
    "actimeo=30",
    "nosharesock",
  ]
}

resource "kubernetes_persistent_volume_claim_v1" "jobs" {
  count = local.use_files ? 1 : 0

  metadata {
    name      = local.jobs_claim
    namespace = local.ns
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.agentic_files[0].metadata[0].name
    resources {
      requests = {
        storage = var.jobs_storage_size
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "vortex" {
  count = local.use_files ? 1 : 0

  metadata {
    name      = local.vortex_claim
    namespace = local.ns
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.agentic_files[0].metadata[0].name
    resources {
      requests = {
        storage = var.vortex_storage_size
      }
    }
  }
}
