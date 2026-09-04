variable "project" {
  type    = string
  default = "webapp"
}

variable "environment" {
  type = string
}

variable "resource_group_name" {
  description = "Pre-created by bootstrap; location is inherited from it."
  type        = string
}

# No defaults: each environment must state its own address space in terraform.tfvars.
# Overlapping ranges cannot be VNet-peered, so a silent default would block the
# hub-and-spoke topology later. dev 10.10 / staging 10.15 / prod 10.20.
variable "vnet_cidr" {
  type = string
}

variable "aks_subnet_cidr" {
  type = string
}

variable "aks_sku_tier" {
  type    = string
  default = "Free"
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

variable "availability_zones" {
  type    = list(string)
  default = []
}

variable "user_node_pool" {
  type = object({
    vm_size   = string
    min_count = number
    max_count = number
  })
  default = null
}

variable "authorized_ip_ranges" {
  type    = list(string)
  default = []
}

# Identity inputs are supplied via TF_VAR_* (CI variables / local *.auto.tfvars), not committed.
variable "deployer_object_id" {
  type    = string
  default = null
}

variable "cluster_admin_object_ids" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
