# see https://gitlab.com/libosinfo/osinfo-db
locals {
  os_id = "http://libosinfo.org/linux/2024"
}

# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.9/docs/resources/network
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.9/docs/resources/network.md
resource "libvirt_network" "talos" {
  name = var.prefix
  domain = {
    name = var.cluster_node_domain
  }
  forward = {
    nat = {
      ports = [
        {
          start = 1024
          end   = 65535
        }
      ]
    }
  }
  ips = [
    {
      address = cidrhost(var.cluster_node_network, 1)
      netmask = cidrnetmask(var.cluster_node_network)
      dhcp = {
        ranges = [
          {
            start = cidrhost(var.cluster_node_network, 2)
            end   = cidrhost(var.cluster_node_network, -2)
          }
        ]
        hosts = concat(
          [
            for dc in local.controller_nodes : {
              mac = dc.mac
              ip  = dc.address
            }
          ],
          [
            for dc in local.worker_nodes : {
              mac = dc.mac
              ip  = dc.address
            }
          ],
        )
      }
    }
  ]
}

# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.9/docs/resources/volume
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.9/docs/resources/volume.md
resource "libvirt_volume" "controller" {
  count    = var.controller_count
  pool     = "default"
  name     = "${var.prefix}_c${count.index}.img"
  capacity = 40 * 1024 * 1024 * 1024 # 40GiB.
  target = {
    format = {
      type = "qcow2"
    }
  }
  backing_store = {
    format = {
      type = "qcow2"
    }
    path = "/var/lib/libvirt/images/${var.talos_libvirt_base_volume_name}"
  }
}

# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.9/docs/resources/volume
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.9/docs/resources/volume.md
resource "libvirt_volume" "worker" {
  count    = var.worker_count
  pool     = "default"
  name     = "${var.prefix}_w${count.index}.img"
  capacity = 40 * 1024 * 1024 * 1024 # 40GiB.
  target = {
    format = {
      type = "qcow2"
    }
  }
  backing_store = {
    format = {
      type = "qcow2"
    }
    path = "/var/lib/libvirt/images/${var.talos_libvirt_base_volume_name}"
  }
}

# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.9/docs/resources/volume
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.9/docs/resources/volume.md
resource "libvirt_volume" "worker_data0" {
  count    = var.worker_count
  pool     = "default"
  name     = "${var.prefix}_w${count.index}d0.img"
  capacity = 32 * 1024 * 1024 * 1024 # 32GiB.
  target = {
    format = {
      type = "qcow2"
    }
  }
}

# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.9/docs/resources/domain
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.9/docs/resources/domain.md
resource "libvirt_domain" "controller" {
  count       = var.controller_count
  name        = "${var.prefix}_${local.controller_nodes[count.index].name}"
  description = "created from ${path.cwd}"
  running     = true
  type        = "kvm"
  vcpu        = 4
  memory      = 4 * 1024
  memory_unit = "MiB"
  features = {
    acpi = true
    apic = {}
    pae  = true
  }
  metadata = {
    xml = <<-EOF
      <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
        <libosinfo:os id="${local.os_id}"/>
      </libosinfo:libosinfo>
      EOF
  }
  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    firmware     = "efi"
    firmware_info = {
      features = [
        {
          name    = "enrolled-keys"
          enabled = "no"
        },
        {
          name    = "secure-boot"
          enabled = "no"
        },
      ]
    }
  }
  cpu = {
    mode = "host-passthrough"
  }
  devices = {
    graphics = [
      {
        spice = {
          auto_port = true
          listeners = [
            {
              address = {}
            }
          ]
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "qxl"
          primary = "yes"
          vram    = 65536
          ram     = 65536
          vga_mem = 16384
          heads   = 1
        }
      }
    ]
    controllers = [
      {
        type  = "scsi"
        model = "virtio-scsi"
      },
    ]
    channels = [
      {
        source = {
          unix = {
            mode = "bind"
          }
        }
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      },
      {
        source = {
          spice_vmc = true
        }
        target = {
          virt_io = {
            name = "com.redhat.spice.0"
          }
        }
      }
    ]
    rngs = [
      {
        model = "virtio"
        backend = {
          random = "/dev/urandom"
        }
      }
    ]
    tpms = [
      {
        model = "tpm-crb"
        backend = {
          emulator = {
            version = "2.0"
          }
        }
      }
    ]
    disks = [
      {
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_volume.controller[count.index].pool
            volume = libvirt_volume.controller[count.index].name
          }
        }
        target = {
          bus = "scsi"
          dev = "sda"
        }
        wwn = format("000000000000aa%02x", count.index)
      },
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        mac = {
          address = local.controller_nodes[count.index].mac
        }
        source = {
          network = {
            network = libvirt_network.talos.name
          }
        }
        wait_for_ip = {
          network = var.cluster_node_network
          source  = "agent"
          timeout = 300 # 300s (5m).
        }
      }
    ]
  }
}

# see https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.9/docs/resources/domain
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.9.9/docs/resources/domain.md
resource "libvirt_domain" "worker" {
  count       = var.worker_count
  name        = "${var.prefix}_${local.worker_nodes[count.index].name}"
  description = "created from ${path.cwd}"
  running     = true
  type        = "kvm"
  vcpu        = 4
  memory      = 4 * 1024
  memory_unit = "MiB"
  features = {
    acpi = true
    apic = {}
    pae  = true
  }
  metadata = {
    xml = <<-EOF
      <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
        <libosinfo:os id="${local.os_id}"/>
      </libosinfo:libosinfo>
      EOF
  }
  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    firmware     = "efi"
    firmware_info = {
      features = [
        {
          name    = "enrolled-keys"
          enabled = "no"
        },
        {
          name    = "secure-boot"
          enabled = "no"
        },
      ]
    }
  }
  cpu = {
    mode = "host-passthrough"
  }
  devices = {
    graphics = [
      {
        spice = {
          auto_port = true
          listeners = [
            {
              address = {}
            }
          ]
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "qxl"
          primary = "yes"
          vram    = 65536
          ram     = 65536
          vga_mem = 16384
          heads   = 1
        }
      }
    ]
    controllers = [
      {
        type  = "scsi"
        model = "virtio-scsi"
      },
    ]
    channels = [
      {
        source = {
          unix = {
            mode = "bind"
          }
        }
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      },
      {
        source = {
          spice_vmc = true
        }
        target = {
          virt_io = {
            name = "com.redhat.spice.0"
          }
        }
      }
    ]
    rngs = [
      {
        model = "virtio"
        backend = {
          random = "/dev/urandom"
        }
      }
    ]
    tpms = [
      {
        model = "tpm-crb"
        backend = {
          emulator = {
            version = "2.0"
          }
        }
      }
    ]
    disks = [
      {
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_volume.worker[count.index].pool
            volume = libvirt_volume.worker[count.index].name
          }
        }
        target = {
          bus = "scsi"
          dev = "sda"
        }
        wwn = format("000000000000aa%02x", count.index)
      },
      {
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_volume.worker_data0[count.index].pool
            volume = libvirt_volume.worker_data0[count.index].name
          }
        }
        target = {
          bus = "scsi"
          dev = "sdb"
        }
        wwn = format("000000000000ab%02x", count.index)
      },
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        mac = {
          address = local.worker_nodes[count.index].mac
        }
        source = {
          network = {
            network = libvirt_network.talos.name
          }
        }
        wait_for_ip = {
          network = var.cluster_node_network
          source  = "agent"
          timeout = 300 # 300s (5m).
        }
      }
    ]
  }
}
