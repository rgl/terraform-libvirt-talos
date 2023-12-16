# see https://github.com/siderolabs/talos/releases
# see https://www.talos.dev/v1.6/introduction/support-matrix/
variable "talos_version" {
  type    = string
  default = "1.6.0"
  validation {
    condition     = can(regex("^\\d+(\\.\\d+)+", var.talos_version))
    error_message = "Must be a version number."
  }
}

# see https://github.com/siderolabs/kubelet/pkgs/container/kubelet
# see https://www.talos.dev/v1.6/introduction/support-matrix/
variable "kubernetes_version" {
  type    = string
  default = "1.26.11"
  validation {
    condition     = can(regex("^\\d+(\\.\\d+)+", var.kubernetes_version))
    error_message = "Must be a version number."
  }
}

variable "cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "example"
}

variable "cluster_vip" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "10.17.3.9"
}

variable "cluster_endpoint" {
  description = "The k8s api-server (VIP) endpoint"
  type        = string
  default     = "https://10.17.3.9:6443" # k8s api-server endpoint.
}

variable "cluster_node_network_prefix" {
  description = "The IP network prefix of the cluster nodes"
  type        = string
  default     = "10.17.3"
}

variable "cluster_node_domain" {
  description = "the DNS domain of the cluster nodes"
  type        = string
  default     = "talos.test"
}

variable "controller_count" {
  type    = number
  default = 1
  validation {
    condition     = var.controller_count >= 1
    error_message = "Must be 1 or more."
  }
}

variable "worker_count" {
  type    = number
  default = 1
  validation {
    condition     = var.worker_count >= 1
    error_message = "Must be 1 or more."
  }
}

variable "talos_libvirt_base_volume_name" {
  type    = string
  default = "talos-1.6.0.qcow2"
  validation {
    condition     = can(regex(".+\\.qcow2+$", var.talos_libvirt_base_volume_name))
    error_message = "Must be a name with a .qcow2 extension."
  }
}

variable "prefix" {
  type    = string
  default = "terraform_talos_example"
}
