resource "random_password" "monitoring" {
  length  = 24
  special = false
}

resource "random_password" "agentic_instance" {
  count = var.enable_agentic ? 1 : 0

  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "db" {
  metadata {
    name      = "sonarqube-db-credentials"
    namespace = local.ns
  }
  data = {
    password = random_password.postgres.result
  }
}

resource "kubernetes_secret_v1" "monitoring" {
  metadata {
    name      = "sonarqube-monitoring-passcode"
    namespace = local.ns
  }
  data = {
    passcode = random_password.monitoring.result
  }
}

# Mandatory for any agentic component. A chart pre-install hook expands this into
# one signing key per communication hop.
resource "kubernetes_secret_v1" "agentic_instance" {
  count = var.enable_agentic ? 1 : 0

  metadata {
    name      = "agentic-instance-secret"
    namespace = local.ns
  }
  data = {
    instance-secret = random_password.agentic_instance[0].result
  }
}

# Same credentials, two secrets: the Orchestrator reads AGENTIC_STORAGE_*, Vortex
# reads SONAR_AGENTIC_STORAGE_*. The chart reads both key names literally.
resource "kubernetes_secret_v1" "agentic_storage" {
  count = var.enable_agentic ? 1 : 0

  metadata {
    name      = "agentic-storage-creds"
    namespace = local.ns
  }
  data = {
    AGENTIC_STORAGE_ACCESS_KEY = "sonarqube"
    AGENTIC_STORAGE_SECRET_KEY = random_password.minio[0].result
  }
}

resource "kubernetes_secret_v1" "vortex_storage" {
  count = var.enable_agentic ? 1 : 0

  metadata {
    name      = "vortex-storage-creds"
    namespace = local.ns
  }
  data = {
    SONAR_AGENTIC_STORAGE_ACCESS_KEY = "sonarqube"
    SONAR_AGENTIC_STORAGE_SECRET_KEY = random_password.minio[0].result
  }
}
