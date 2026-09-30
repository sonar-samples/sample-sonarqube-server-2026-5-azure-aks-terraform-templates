# --------------------------------------------------------------------------
# Public DNS: an A record in an Azure DNS zone that already exists.
# --------------------------------------------------------------------------

locals {
  sonarqube_fqdn = "${var.host_name}.${var.domain_name}"
  sonarqube_url  = "https://${local.sonarqube_fqdn}"
}

data "azurerm_dns_zone" "this" {
  name                = var.domain_name
  resource_group_name = var.dns_resource_group_name
}

resource "azurerm_dns_a_record" "sonarqube" {
  name                = var.host_name
  zone_name           = data.azurerm_dns_zone.this.name
  resource_group_name = var.dns_resource_group_name
  ttl                 = 300
  records             = [azurerm_public_ip.appgw.ip_address]
  tags                = var.tags
}
