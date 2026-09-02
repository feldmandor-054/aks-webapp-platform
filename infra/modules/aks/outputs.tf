output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "ingress_class_name" {
  description = "IngressClass installed by the application routing add-on."
  value       = "webapprouting.kubernetes.azure.com"
}
