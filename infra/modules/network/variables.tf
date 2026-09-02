variable "name_prefix" {
  description = "Prefix used for resource names, e.g. webapp-dev."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "vnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "aks_subnet_cidr" {
  type    = string
  default = "10.10.0.0/22"
}

variable "tags" {
  type    = map(string)
  default = {}
}
