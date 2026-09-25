resource "helm_release" "sonarqube" {
  name       = "sonarqube"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube"
  version    = var.sonarqube_chart_version
  namespace  = local.ns
  timeout    = 1800

  values = [templatefile("${path.module}/sonarqube-values.yaml.tftpl", {
    postgres_fqdn       = azurerm_postgresql_flexible_server.this.fqdn
    minio_endpoint      = local.minio_endpoint
    agentic             = var.enable_agentic
    runtime_class       = var.sandbox_runtime_class
    llm_domains         = var.llm_allowed_domains
    settings_encryption = var.enable_settings_encryption
  })]

  depends_on = [
    azurerm_kubernetes_cluster_node_pool.sandbox,
    azurerm_postgresql_flexible_server_firewall_rule.aks,
    helm_release.minio,
    kubernetes_secret_v1.db,
    kubernetes_secret_v1.monitoring,
    kubernetes_secret_v1.agentic_instance,
    kubernetes_secret_v1.agentic_storage,
    kubernetes_secret_v1.vortex_storage,
  ]
}
