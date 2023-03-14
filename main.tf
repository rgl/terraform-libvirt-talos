# see https://github.com/hashicorp/terraform
terraform {
  required_version = "1.4.0"
  required_providers {
    # see https://registry.terraform.io/providers/hashicorp/random
    random = {
      source  = "hashicorp/random"
      version = "3.4.3"
    }
    # see https://registry.terraform.io/providers/hashicorp/template
    template = {
      source  = "hashicorp/template"
      version = "2.2.0"
    }
    # see https://registry.terraform.io/providers/dmacvicar/libvirt
    # see https://github.com/dmacvicar/terraform-provider-libvirt
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.7.1"
    }
    # see https://registry.terraform.io/providers/siderolabs/talos
    # see https://github.com/siderolabs/terraform-provider-talos
    talos = {
      source  = "siderolabs/talos"
      version = "0.1.2"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

provider "talos" {
}

variable "prefix" {
  default = "terraform_talos_example"
}

variable "controller_count" {
  type    = number
  default = 3
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

variable "cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "example"
}

locals {
  talos_version      = "1.3.5"
  kubernetes_version = "1.26.2"
  cluster_vip        = "10.17.3.9"
  cluster_endpoint   = "https://${local.cluster_vip}:6443" # k8s api-server endpoint.
  controller_nodes = [
    for i in range(var.controller_count) : {
      name    = "c${i}"
      address = "10.17.3.${10 + i}"
    }
  ]
  worker_nodes = [
    for i in range(var.worker_count) : {
      name    = "w${i}"
      address = "10.17.3.${20 + i}"
    }
  ]
  common_machine_config = {
    cluster = {
      # see https://www.talos.dev/v1.3/talos-guides/discovery/
      # see https://www.talos.dev/v1.3/reference/configuration/#clusterdiscoveryconfig
      discovery = {
        enabled = true
        registries = {
          kubernetes = {
            disabled = false
          }
          service = {
            disabled = true
          }
        }
      }
    }
  }
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/website/docs/r/network.markdown
resource "libvirt_network" "talos" {
  name      = var.prefix
  mode      = "nat"
  domain    = "talos.test"
  addresses = ["10.17.3.0/24"]
  dhcp {
    enabled = false
  }
  dns {
    enabled    = true
    local_only = false
  }
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/website/docs/r/volume.html.markdown
resource "libvirt_volume" "controller" {
  count            = var.controller_count
  name             = "${var.prefix}_c${count.index}.img"
  base_volume_name = "talos-${local.talos_version}-amd64.qcow2"
  format           = "qcow2"
  size             = 40 * 1024 * 1024 * 1024 # 40GiB.
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/website/docs/r/volume.html.markdown
resource "libvirt_volume" "worker" {
  count            = var.worker_count
  name             = "${var.prefix}_w${count.index}.img"
  base_volume_name = "talos-${local.talos_version}-amd64.qcow2"
  format           = "qcow2"
  size             = 40 * 1024 * 1024 * 1024 # 40GiB.
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/website/docs/r/domain.html.markdown
resource "libvirt_domain" "controller" {
  count = var.controller_count
  name  = "${var.prefix}_${local.controller_nodes[count.index].name}"
  cpu {
    mode = "host-passthrough"
  }
  vcpu   = 4
  memory = 2 * 1024
  disk {
    volume_id = libvirt_volume.controller[count.index].id
    scsi      = true
  }
  network_interface {
    network_id = libvirt_network.talos.id
    addresses  = [local.controller_nodes[count.index].address]
  }
  lifecycle {
    ignore_changes = [
      disk[0].wwn,
    ]
  }
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/website/docs/r/domain.html.markdown
resource "libvirt_domain" "worker" {
  count = var.worker_count
  name  = "${var.prefix}_${local.worker_nodes[count.index].name}"
  cpu {
    mode = "host-passthrough"
  }
  vcpu   = 4
  memory = 2 * 1024
  disk {
    volume_id = libvirt_volume.worker[count.index].id
    scsi      = true
  }
  network_interface {
    network_id = libvirt_network.talos.id
    addresses  = [local.worker_nodes[count.index].address]
  }
  lifecycle {
    ignore_changes = [
      disk[0].wwn,
    ]
  }
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/machine_secrets
resource "talos_machine_secrets" "machine_secrets" {
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/machine_configuration_controlplane
resource "talos_machine_configuration_controlplane" "controller" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.machine_secrets.machine_secrets
  kubernetes_version = local.kubernetes_version
  config_patches = [
    yamlencode(local.common_machine_config),
    yamlencode({
      machine = {
        network = {
          interfaces = [
            # see https://www.talos.dev/v1.3/talos-guides/network/vip/
            {
              interface = "eth0"
              dhcp      = true
              vip = {
                ip = local.cluster_vip
              }
            }
          ]
        }
      }
    })
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/machine_configuration_worker
resource "talos_machine_configuration_worker" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.machine_secrets.machine_secrets
  kubernetes_version = local.kubernetes_version
  config_patches = [
    yamlencode(local.common_machine_config),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/client_configuration
resource "talos_client_configuration" "talos" {
  cluster_name    = var.cluster_name
  machine_secrets = talos_machine_secrets.machine_secrets.machine_secrets
  endpoints       = [for node in local.controller_nodes : node.address]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "controller" {
  count                 = var.controller_count
  talos_config          = talos_client_configuration.talos.talos_config
  machine_configuration = talos_machine_configuration_controlplane.controller.machine_config
  endpoint              = local.controller_nodes[count.index].address
  node                  = local.controller_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/sda"
        }
        network = {
          hostname = local.controller_nodes[count.index].name
        }
      }
    }),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "worker" {
  count                 = var.worker_count
  talos_config          = talos_client_configuration.talos.talos_config
  machine_configuration = talos_machine_configuration_worker.worker.machine_config
  endpoint              = local.worker_nodes[count.index].address
  node                  = local.worker_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/sda"
        }
        network = {
          hostname = local.worker_nodes[count.index].name
        }
      }
    }),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/machine_bootstrap
resource "talos_machine_bootstrap" "talos" {
  talos_config = talos_client_configuration.talos.talos_config
  endpoint     = local.controller_nodes[0].address
  node         = local.controller_nodes[0].address
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.1.1/docs/resources/cluster_kubeconfig
resource "talos_cluster_kubeconfig" "talos" {
  talos_config = talos_client_configuration.talos.talos_config
  endpoint     = local.controller_nodes[0].address
  node         = local.controller_nodes[0].address
}

output "talosconfig" {
  value     = talos_client_configuration.talos.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.talos.kube_config
  sensitive = true
}

output "controllers" {
  value = join(",", [for node in local.controller_nodes : node.address])
}

output "workers" {
  value = join(",", [for node in local.worker_nodes : node.address])
}
