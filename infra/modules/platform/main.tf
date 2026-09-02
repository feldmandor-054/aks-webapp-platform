# Composition module: one complete environment (network + AKS + access).
# Environments (infra/envs/*) only differ in the values they pass in.
terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  })
}

# Resource group is pre-created by bootstrap (landing-zone style) so the infra
# identity can be scoped to it instead of the whole subscription.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

module "network" {
  source              = "../network"
  name_prefix         = local.name_prefix
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  vnet_cidr           = var.vnet_cidr
  aks_subnet_cidr     = var.aks_subnet_cidr
  tags                = local.tags
}

module "aks" {
  source              = "../aks"
  name                = "aks-${local.name_prefix}"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  subnet_id           = module.network.aks_subnet_id

  sku_tier              = var.aks_sku_tier
  node_vm_size          = var.node_vm_size
  node_min_count        = var.node_min_count
  node_max_count        = var.node_max_count
  availability_zones    = var.availability_zones
  dedicated_system_pool = var.user_node_pool != null
  user_node_pool        = var.user_node_pool
  authorized_ip_ranges  = var.authorized_ip_ranges

  deployer_object_id       = var.deployer_object_id
  cluster_admin_object_ids = var.cluster_admin_object_ids
  tags                     = local.tags
}
