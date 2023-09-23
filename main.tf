# see https://github.com/hashicorp/terraform
terraform {
  required_version = "1.5.7"
  required_providers {
    # see https://registry.terraform.io/providers/hashicorp/random
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
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
      version = "0.3.3"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

provider "talos" {
}

variable "prefix" {
  type    = string
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
  qemu_guest_agent_extension_version = "8.1.0"  # see https://github.com/siderolabs/extensions/pkgs/container/qemu-guest-agent
  kubernetes_version                 = "1.26.8" # see https://github.com/siderolabs/kubelet/pkgs/container/kubelet
  talos_version                      = "1.5.3"  # see https://github.com/siderolabs/talos/releases
  talos_version_tag                  = "v${local.talos_version}"
  cluster_vip                        = "10.17.3.9"
  cluster_endpoint                   = "https://${local.cluster_vip}:6443" # k8s api-server endpoint.
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
    machine = {
      # NB these changes will only be applied after a talos upgrade, which we
      #    do in the "do" script.
      #    NB this is needed because we are using the upstream nocloud image,
      #       which already has talos installed.
      #    TODO stop using the .machine.install configuration and generate an
      #         image with this already baked in; then use that image as the
      #         VM image.
      install = {
        extensions = [
          {
            image = "ghcr.io/siderolabs/qemu-guest-agent:${local.qemu_guest_agent_extension_version}"
          },
        ]
      }
    }
    cluster = {
      # see https://www.talos.dev/v1.5/talos-guides/discovery/
      # see https://www.talos.dev/v1.5/reference/configuration/#clusterdiscoveryconfig
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
  count      = var.controller_count
  name       = "${var.prefix}_${local.controller_nodes[count.index].name}"
  qemu_agent = true
  machine    = "q35"
  cpu {
    mode = "host-passthrough"
  }
  vcpu   = 4
  memory = 2 * 1024
  video {
    type = "qxl"
  }
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
  count      = var.worker_count
  name       = "${var.prefix}_${local.worker_nodes[count.index].name}"
  qemu_agent = true
  machine    = "q35"
  cpu {
    mode = "host-passthrough"
  }
  vcpu   = 4
  memory = 2 * 1024
  video {
    type = "qxl"
  }
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

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/data-sources/machine_configuration
data "talos_machine_configuration" "controller" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "controlplane"
  talos_version      = local.talos_version_tag
  kubernetes_version = local.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
    yamlencode({
      machine = {
        network = {
          interfaces = [
            # see https://www.talos.dev/v1.5/talos-guides/network/vip/
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

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/data-sources/machine_configuration
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "worker"
  talos_version      = local.talos_version_tag
  kubernetes_version = local.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/data-sources/client_configuration
data "talos_client_configuration" "talos" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoints            = [for node in local.controller_nodes : node.address]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/data-sources/cluster_kubeconfig
data "talos_cluster_kubeconfig" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_bootstrap.talos,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/resources/machine_secrets
resource "talos_machine_secrets" "talos" {
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "controller" {
  count                       = var.controller_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controller.machine_configuration
  endpoint                    = local.controller_nodes[count.index].address
  node                        = local.controller_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = local.controller_nodes[count.index].name
        }
      }
    }),
  ]
  depends_on = [
    libvirt_domain.controller,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = local.worker_nodes[count.index].address
  node                        = local.worker_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = local.worker_nodes[count.index].name
        }
      }
    }),
  ]
  depends_on = [
    libvirt_domain.worker,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.3.3/docs/resources/machine_bootstrap
resource "talos_machine_bootstrap" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_configuration_apply.controller,
  ]
}

output "talosconfig" {
  value     = data.talos_client_configuration.talos.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = data.talos_cluster_kubeconfig.talos.kubeconfig_raw
  sensitive = true
}

output "controllers" {
  value = join(",", [for node in local.controller_nodes : node.address])
}

output "workers" {
  value = join(",", [for node in local.worker_nodes : node.address])
}
