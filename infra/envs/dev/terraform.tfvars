# Environment-specific configuration for DEV. Reusable logic lives in ../../modules.
environment         = "dev"
resource_group_name = "rg-webapp-dev"

# Cheapest real cluster: Free control plane, one burstable node, autoscale to 2.
# Free subscriptions restrict VM SKUs per region (B2s was rejected in northeurope); B2als_v2
# (2 vCPU / 4 GiB, AMD) is allowed in israelcentral - check with `az vm list-skus -l <region>`.
aks_sku_tier       = "Free"
node_vm_size       = "Standard_B2als_v2"
node_min_count     = 1
node_max_count     = 2
availability_zones = []

# Dev API server is public; restrict with authorized_ip_ranges = ["<office-cidr>"] when known.
authorized_ip_ranges = []

tags = {
  cost_center = "assignment"
}
