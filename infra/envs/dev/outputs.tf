output "resource_group_name" {
  value = module.platform.resource_group_name
}

output "aks_cluster_name" {
  value = module.platform.aks_cluster_name
}

output "aks_node_resource_group" {
  value = module.platform.aks_node_resource_group
}

output "ingress_class_name" {
  value = module.platform.ingress_class_name
}

output "kubectl_hint" {
  value = module.platform.kubectl_hint
}
