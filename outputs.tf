output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "kubernetes_version" {
  value = azurerm_kubernetes_cluster.this.kubernetes_version
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "aks_egress_ip" {
  description = "Address allowed through the PostgreSQL firewall."
  value       = data.azurerm_public_ip.aks_egress.ip_address
}

output "sonarqube_status" {
  value = helm_release.sonarqube.status
}

output "get_credentials_command" {
  value = "az aks get-credentials -g ${azurerm_resource_group.this.name} -n ${azurerm_kubernetes_cluster.this.name}"
}

output "port_forward_command" {
  value = "kubectl port-forward -n ${local.ns} svc/sonarqube-sonarqube 9000:9000"
}
