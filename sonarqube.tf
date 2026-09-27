resource "helm_release" "sonarqube" {
  name       = "sonarqube"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube"
  version    = var.sonarqube_chart_version
  namespace  = local.ns
  timeout    = 1800

  values = [templatefile("${path.module}/sonarqube-values.yaml.tftpl", {
    postgres_fqdn       = azurerm_postgresql_flexible_server.this.fqdn
    server_image_tag    = var.sonarqube_image_tag
    images              = var.agentic_images
    jobs_claim          = local.jobs_claim
    vortex_claim        = local.vortex_claim
    jobs_base_dir       = local.jobs_base_dir
    vortex_base_dir     = local.vortex_base_dir
    agentic             = var.enable_agentic
    runtime_class       = var.sandbox_runtime_class
    llm_domains         = var.llm_allowed_domains
    settings_encryption = var.enable_settings_encryption
  })]

  depends_on = [
    azurerm_kubernetes_cluster_node_pool.sandbox,
    azurerm_postgresql_flexible_server_firewall_rule.aks,
    kubernetes_persistent_volume_claim_v1.jobs,
    kubernetes_persistent_volume_claim_v1.vortex,
    kubernetes_secret_v1.db,
    kubernetes_secret_v1.monitoring,
    kubernetes_secret_v1.agentic_instance,
  ]
}
