terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

data "azurerm_client_config" "current" {}

# Control-plane identity. User-assigned so its role assignments exist before the
# cluster is created (avoids the classic "cluster can't join subnet" race).
resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-${var.name}-cp"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_assignment" "cp_subnet_network_contributor" {
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  tags                = var.tags

  # Patch upgrades applied automatically; node OS images refreshed by AKS.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Entra ID + Azure RBAC for all data-plane access; no static local admin creds.
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  dynamic "api_server_access_profile" {
    for_each = length(var.authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    vnet_subnet_id              = var.subnet_id
    zones                       = var.availability_zones
    auto_scaling_enabled        = true
    min_count                   = var.node_min_count
    max_count                   = var.node_max_count
    os_disk_size_gb             = var.node_os_disk_size_gb
    os_disk_type                = "Managed"
    temporary_name_for_rotation = "systmp"
    # Dev runs workloads on the system pool (cost). Prod sets this true and adds a user pool.
    only_critical_addons_enabled = var.dedicated_system_pool
    upgrade_settings {
      max_surge = "33%"
    }
    tags = var.tags
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"
    load_balancer_sku   = "standard"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.250.0.0/16"
    dns_service_ip      = "10.250.0.10"
  }

  # Container Insights -> Log Analytics (logs + basic metrics).
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  # Managed NGINX ingress controller (application routing add-on).
  web_app_routing {
    dns_zone_ids = []
  }

  depends_on = [azurerm_role_assignment.cp_subnet_network_contributor]

  lifecycle {
    ignore_changes = [
      # Autoscaler moves node_count; never fight it from Terraform.
      default_node_pool[0].node_count,
    ]
  }
}

# Optional dedicated user pool (prod). Kept in the module so prod/dev share one code path.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  count = var.user_node_pool == null ? 0 : 1

  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_pool.vm_size
  vnet_subnet_id        = var.subnet_id
  zones                 = var.availability_zones
  auto_scaling_enabled  = true
  min_count             = var.user_node_pool.min_count
  max_count             = var.user_node_pool.max_count
  os_disk_size_gb       = var.node_os_disk_size_gb
  mode                  = "User"
  tags                  = var.tags
}

# --- Data-plane access -------------------------------------------------------

# CI/CD deployer: may read cluster credentials and manage workloads.
# Cluster-scoped RBAC Cluster Admin is needed because Helm creates namespaces;
# namespace-scoped "RBAC Writer" is the tighter follow-up once namespaces are IaC-managed.
resource "azurerm_role_assignment" "deployer_cluster_user" {
  count                = var.deployer_object_id == null ? 0 : 1
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.deployer_object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployer_rbac_admin" {
  count                = var.deployer_object_id == null ? 0 : 1
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.deployer_object_id
  principal_type       = "ServicePrincipal"
}

# Humans (platform engineers) who need kubectl access.
resource "azurerm_role_assignment" "human_cluster_admin" {
  for_each             = toset(var.cluster_admin_object_ids)
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
  principal_type       = "User"
}

resource "azurerm_role_assignment" "human_cluster_user" {
  for_each             = toset(var.cluster_admin_object_ids)
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
  principal_type       = "User"
}
