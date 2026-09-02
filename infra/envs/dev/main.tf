terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # Remote state in Azure Blob Storage. Names come from backend.hcl (written by
  # infra/bootstrap/bootstrap.sh):  terraform init -backend-config=backend.hcl
  backend "azurerm" {
    use_azuread_auth = true
  }
}

# subscription_id / tenant_id come from ARM_* env vars (OIDC in CI, az login locally).
provider "azurerm" {
  features {}
  # Provider registration needs subscription-level rights; bootstrap does it once.
  resource_provider_registrations = "none"
}

module "platform" {
  source = "../../modules/platform"

  project             = var.project
  environment         = var.environment
  resource_group_name = var.resource_group_name

  vnet_cidr       = var.vnet_cidr
  aks_subnet_cidr = var.aks_subnet_cidr

  aks_sku_tier         = var.aks_sku_tier
  node_vm_size         = var.node_vm_size
  node_min_count       = var.node_min_count
  node_max_count       = var.node_max_count
  availability_zones   = var.availability_zones
  user_node_pool       = var.user_node_pool
  authorized_ip_ranges = var.authorized_ip_ranges

  deployer_object_id       = var.deployer_object_id
  cluster_admin_object_ids = var.cluster_admin_object_ids
  tags                     = var.tags
}
