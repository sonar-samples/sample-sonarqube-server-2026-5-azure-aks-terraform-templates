resource "kubernetes_namespace_v1" "sonarqube" {
  metadata {
    name = "sonarqube"
  }
}

locals {
  ns              = kubernetes_namespace_v1.sonarqube.metadata[0].name
  jobs_claim      = "agentic-jobs"
  vortex_claim    = "vortex-context"
  jobs_base_dir   = "/agentic-storage"
  vortex_base_dir = "/vortex-context"
}

# Azure Files over SMB, not MinIO: Azure Blob has no S3-compatible API, and the MinIO
# container images are no longer anonymously pullable.
#
# The built-in azurefile-csi class sets no uid/gid/file_mode, so an SMB mount lands as
# root-owned and the agentic containers (which run as 900, 1000 and 10001) cannot write.
# This class sets permissive modes instead, which also avoids the shared-fsGroup
# coordination the chart warns about for block storage.
resource "kubernetes_storage_class_v1" "agentic_files" {
  count = var.enable_agentic ? 1 : 0

  metadata {
    name = "sonarqube-agentic-files"
  }
  storage_provisioner    = "file.csi.azure.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  parameters = {
    skuName = "Standard_LRS"
  }

  mount_options = [
    "dir_mode=0777",
    "file_mode=0777",
    "uid=0",
    "gid=0",
    "mfsymlinks",
    "cache=strict",
    "actimeo=30",
    "nosharesock",
  ]
}

# Job artifacts. ReadWriteMany is required: the Orchestrator and both runtimes mount
# this at the same time. Each runtime mounts only its own subdirectory.
resource "kubernetes_persistent_volume_claim_v1" "jobs" {
  count = var.enable_agentic ? 1 : 0

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

# Vortex analyzer context. A separate store from job artifacts: SonarQube Server writes
# it, Vortex reads it, and the two datasets have opposite retention lifecycles.
resource "kubernetes_persistent_volume_claim_v1" "vortex" {
  count = var.enable_agentic ? 1 : 0

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
