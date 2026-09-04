# Environment-specific configuration for PROD. NOT applied in this assignment (cost);
# it documents how the same modules scale to a production posture.
environment         = "prod"
resource_group_name = "rg-webapp-prod"

# Non-overlapping with dev (10.10.0.0/16) and the reserved staging range (10.15.0.0/16),
# so all environments can be peered into a hub VNet without renumbering. A /22 subnet gives
# ~1000 node/pod-overlay addresses, enough for the 3-12 node user pool.
vnet_cidr       = "10.20.0.0/16"
aks_subnet_cidr = "10.20.0.0/22"

# Standard tier = 99.95% API-server SLA; zone-redundant nodes; workloads isolated on a user pool.
aks_sku_tier       = "Standard"
node_vm_size       = "Standard_D2s_v5"
node_min_count     = 3
node_max_count     = 5
availability_zones = ["1", "2", "3"]

user_node_pool = {
  vm_size   = "Standard_D4s_v5"
  min_count = 3
  max_count = 12
}

# API server reachable only from corporate egress / CI runners (private cluster is the next step).
authorized_ip_ranges = ["203.0.113.0/24"]

tags = {
  cost_center = "platform"
  criticality = "high"
}
