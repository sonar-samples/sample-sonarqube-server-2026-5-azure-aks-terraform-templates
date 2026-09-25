provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  kube = azurerm_kubernetes_cluster.this.kube_config[0]
}

# NOTE: these providers read credentials from a cluster created in the same apply.
# That resolves on apply, but is a known weak point on `terraform destroy` and on a
# refresh after the cluster is gone. See README "Known limitations".
provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}

# Helm provider 3.x takes `kubernetes` as an ATTRIBUTE (=), not a nested block.
# The 2.x block syntax fails to parse.
provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}
