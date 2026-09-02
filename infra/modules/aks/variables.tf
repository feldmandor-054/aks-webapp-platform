variable "name" {
  description = "Cluster name, e.g. aks-webapp-dev."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "kubernetes_version" {
  description = "null = AKS default for the region."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "Free (no SLA, dev) or Standard (99.95% uptime SLA)."
  type        = string
  default     = "Free"
  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "node_vm_size" {
  type    = string
  default = "Standard_B2als_v2"
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 2
}

variable "node_os_disk_size_gb" {
  type    = number
  default = 32
}

variable "availability_zones" {
  description = "Empty for single-zone dev; [\"1\",\"2\",\"3\"] for prod."
  type        = list(string)
  default     = []
}

variable "dedicated_system_pool" {
  description = "Taint the system pool so only critical add-ons run there (requires user_node_pool)."
  type        = bool
  default     = false
}

variable "user_node_pool" {
  description = "Optional user node pool for application workloads."
  type = object({
    vm_size   = string
    min_count = number
    max_count = number
  })
  default = null
}

variable "authorized_ip_ranges" {
  description = "CIDRs allowed to reach the API server. Empty = public (dev only)."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "deployer_object_id" {
  description = "Object ID of the CI/CD service principal that deploys workloads."
  type        = string
  default     = null
}

variable "cluster_admin_object_ids" {
  description = "Entra object IDs of humans granted cluster admin."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
