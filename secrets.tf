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

# Mandatory for any agentic component. A chart pre-install hook expands this into one
# signing key per communication hop.
#
# No storage credentials are needed: a filesystem backend is reached by mount, not by
# endpoint and access key.
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
