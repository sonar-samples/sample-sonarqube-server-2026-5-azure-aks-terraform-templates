# --------------------------------------------------------------------------
# ACME certificate (Let's Encrypt by default), validated by DNS-01 against the existing Azure
# DNS zone. The identity running Terraform needs DNS Zone Contributor on that zone.
#
# Renewal is NOT a background process. The provider re-issues the certificate during a plan or
# apply once fewer than min_days_remaining days are left, so something has to run
# `terraform apply` on a schedule shorter than that window.
# --------------------------------------------------------------------------

resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.acme_email
}

# Application Gateway rejects a PFX without a password.
resource "random_password" "p12" {
  length  = 32
  special = false
}

resource "acme_certificate" "sonarqube" {
  account_key_pem          = acme_registration.this.account_key_pem
  common_name              = local.sonarqube_fqdn
  key_type                 = "2048"
  min_days_remaining       = 30
  certificate_p12_password = random_password.p12.result

  dns_challenge {
    provider = "azuredns"
    config = {
      AZURE_SUBSCRIPTION_ID = var.subscription_id
      AZURE_TENANT_ID       = data.azurerm_client_config.current.tenant_id
      AZURE_RESOURCE_GROUP  = var.dns_resource_group_name
      AZURE_ENVIRONMENT     = "public"
    }
  }
}
