output "sonarqube_url" {
  description = "Public HTTPS address of SonarQube Server. Point CI scanners and agent clients here."
  value       = local.sonarqube_url
}

output "appgw_public_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

output "sonarqube_internal_ip" {
  description = "Internal load balancer address. The Application Gateway's only backend."
  value       = local.sonarqube_internal_ip
}

output "certificate_not_after" {
  description = "Certificate expiry. Re-issued on the first plan or apply within 30 days of this date."
  value       = acme_certificate.sonarqube.certificate_not_after
}

output "resource_group_name" {
  value = local.resource_group_name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "kubernetes_version" {
  value = azurerm_kubernetes_cluster.this.kubernetes_version
}

output "postgres_fqdn" {
  description = "Resolves only inside the VNet."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "sonarqube_status" {
  value = helm_release.sonarqube.status
}

output "get_credentials_command" {
  value = "az aks get-credentials -g ${local.resource_group_name} -n ${azurerm_kubernetes_cluster.this.name}"
}

output "port_forward_command" {
  description = "Troubleshooting fallback when the gateway backend is unhealthy."
  value       = "kubectl port-forward -n ${local.ns} svc/sonarqube-sonarqube 9000:9000"
}

output "storage_backend" {
  description = "Which storage backend the agentic components are configured against."
  value       = var.enable_agentic ? var.storage_backend : "n/a (agentic disabled)"
}

output "blob_endpoint" {
  description = "Storage host the runtimes reach through the egress proxy, over the private endpoint. Empty on the filesystem backend."
  value       = local.blob_host
}
