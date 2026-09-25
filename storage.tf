resource "kubernetes_namespace_v1" "sonarqube" {
  metadata {
    name = "sonarqube"
  }
}

locals {
  ns             = kubernetes_namespace_v1.sonarqube.metadata[0].name
  minio_endpoint = "http://minio.sonarqube.svc.cluster.local:9000"
}

resource "random_password" "minio" {
  count = var.enable_agentic ? 1 : 0

  length  = 32
  special = false
}

# S3-compatible storage for agent job artifacts and Vortex analysis context.
# Azure Blob Storage has no S3 API, so an in-cluster object store is the shortest
# path on AKS. Two buckets: the two datasets have opposite retention lifecycles.
#
# The MinIO chart requests 16Gi of memory by default, which will not schedule on a
# mid-sized node.
resource "helm_release" "minio" {
  count = var.enable_agentic ? 1 : 0

  name       = "minio"
  repository = "https://charts.min.io/"
  chart      = "minio"
  namespace  = local.ns

  set = [
    { name = "mode", value = "standalone" },
    { name = "rootUser", value = "sonarqube" },
    { name = "rootPassword", value = random_password.minio[0].result },
    { name = "resources.requests.memory", value = "1Gi" },
    { name = "persistence.size", value = "100Gi" },
    { name = "buckets[0].name", value = "agent-jobs" },
    { name = "buckets[0].policy", value = "none" },
    { name = "buckets[1].name", value = "vortex-context" },
    { name = "buckets[1].policy", value = "none" },
  ]
}
