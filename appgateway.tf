# --------------------------------------------------------------------------
# Application Gateway
#
# Terminates HTTPS on 443 with the ACME certificate and forwards plain HTTP to SonarQube Server on
# 9000, through the internal load balancer or, in gateway-restricted mode, the restricted public
# load balancer IP. Port 80 redirects to HTTPS. SonarQube Server is the only
# workload with an external route: the agentic API is served in-process by the Server, and the
# Orchestrator, Vortex and both runtimes stay ClusterIP.
# --------------------------------------------------------------------------

locals {
  appgw_backend = "sonarqube"
  appgw_cert    = "sonarqube-tls"
  appgw_https   = "https"
  appgw_http    = "http"
  appgw_probe   = "sonarqube-status"
}

resource "azurerm_application_gateway" "this" {
  name                = "${var.cluster_name}-appgw"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  # Standard_v2 does not enforce a request-body limit, so analyzer-context uploads pass. If
  # policy requires WAF_v2, the WAF policy's max_request_body_size_in_kb and
  # file_upload_limit_in_mb apply in Prevention mode and must admit those uploads.
  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = var.appgw_capacity
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  gateway_ip_configuration {
    name      = "gateway"
    subnet_id = azurerm_subnet.appgw.id
  }

  ssl_certificate {
    name     = local.appgw_cert
    data     = acme_certificate.sonarqube.certificate_p12
    password = random_password.p12.result
  }

  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "443"
    port = 443
  }

  frontend_port {
    name = "80"
    port = 80
  }

  backend_address_pool {
    name         = local.appgw_backend
    ip_addresses = [local.sonarqube_backend_ip]
  }

  # 300s rather than the 60s default: large analysis report and analyzer-context uploads can
  # outlast a minute on the first scan of a big project.
  backend_http_settings {
    name                  = local.appgw_backend
    cookie_based_affinity = "Disabled"
    port                  = 9000
    protocol              = "Http"
    request_timeout       = 300
    probe_name            = local.appgw_probe
  }

  probe {
    name                = local.appgw_probe
    protocol            = "Http"
    host                = local.sonarqube_backend_ip
    path                = "/api/system/status"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3

    match {
      status_code = ["200"]
    }
  }

  http_listener {
    name                           = local.appgw_https
    frontend_ip_configuration_name = "public"
    frontend_port_name             = "443"
    protocol                       = "Https"
    ssl_certificate_name           = local.appgw_cert
  }

  http_listener {
    name                           = local.appgw_http
    frontend_ip_configuration_name = "public"
    frontend_port_name             = "80"
    protocol                       = "Http"
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = local.appgw_https
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = local.appgw_https
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = local.appgw_https
    backend_address_pool_name  = local.appgw_backend
    backend_http_settings_name = local.appgw_backend
  }

  request_routing_rule {
    name                        = local.appgw_http
    rule_type                   = "Basic"
    priority                    = 200
    http_listener_name          = local.appgw_http
    redirect_configuration_name = "http-to-https"
  }
}
