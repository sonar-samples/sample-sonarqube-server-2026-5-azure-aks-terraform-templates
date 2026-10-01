terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}
provider "azurerm" {
  features {
    # The blob account has no public endpoint, so the provider must not attempt data-plane calls
    # from the machine running Terraform. Containers are managed through Resource Manager instead.
    storage {
      data_plane_available = false
    }
  }
  subscription_id = var.subscription_id
}

provider "acme" {
  server_url = var.acme_server_url
}

# Passes subscription and tenant to the ACME DNS-01 challenge.
data "azurerm_client_config" "current" {}

locals {
  kube = azurerm_kubernetes_cluster.this.kube_config[0]
}

# NOTE: these providers read credentials from a cluster created in the same apply.
# That resolves on apply, but is a known weak point on `terraform destroy` and on a
# refresh after the cluster is gone. See README "Notes".
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
