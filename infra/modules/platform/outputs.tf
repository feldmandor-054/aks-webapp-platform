output "resource_group_name" {
  value = data.azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_cluster_id" {
  value = module.aks.cluster_id
}

output "aks_node_resource_group" {
  value = module.aks.node_resource_group
}

output "oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "ingress_class_name" {
  value = module.aks.ingress_class_name
}

output "kubectl_hint" {
  value = "az aks get-credentials -g ${data.azurerm_resource_group.this.name} -n ${module.aks.cluster_name} && kubelogin convert-kubeconfig -l azurecli"
}
