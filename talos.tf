locals {
  controller_nodes = [
    for i in range(var.controller_count) : {
      name    = "c${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_controller_hostnum + i)
    }
  ]
  worker_nodes = [
    for i in range(var.worker_count) : {
      name    = "w${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_worker_hostnum + i)
    }
  ]
  common_machine_config = {
    machine = {
      # NB the install section changes are only applied after a talos upgrade
      #    (which we do not do). instead, its preferred to create a custom
      #    talos image, which is created in the installed state.
      #install = {}
      features = {
        # see https://www.talos.dev/v1.10/kubernetes-guides/configuration/kubeprism/
        # see talosctl -n $c0 read /etc/kubernetes/kubeconfig-kubelet | yq .clusters[].cluster.server
        # NB if you use a non-default CNI, you must configure it to use the
        #    https://localhost:7445 kube-apiserver endpoint.
        kubePrism = {
          enabled = true
          port    = 7445
        }
        # see https://www.talos.dev/v1.10/talos-guides/network/host-dns/
        hostDNS = {
          enabled              = true
          forwardKubeDNSToHost = true
        }
      }
      kernel = {
        modules = [
          // piraeus dependencies.
          {
            name = "drbd"
            parameters = [
              "usermode_helper=disabled",
            ]
          },
          {
            name = "drbd_transport_tcp"
          },
        ]
      }
      network = {
        extraHostEntries = [
          {
            ip = local.zot_cluster_ip
            aliases = [
              local.zot_cluster_domain,
            ]
          }
        ]
      }
      registries = {
        config = {
          (local.zot_cluster_host) = {
            auth = {
              username = "talos"
              password = "talos"
            }
          }
        }
        mirrors = {
          (local.zot_cluster_host) = {
            endpoints = [
              local.zot_cluster_url,
            ]
            skipFallback = false
          }
        }
      }
    }
    cluster = {
      # disable kubernetes discovery as its no longer compatible with k8s 1.32+.
      # NB we actually disable the discovery altogether, at the other discovery
      #    mechanism, service discovery, requires the public discovery service
      #    from https://discovery.talos.dev/ (or a custom and paid one running
      #    locally in your network).
      # NB without this, talosctl get members, always returns an empty set.
      # see https://www.talos.dev/v1.10/talos-guides/discovery/
      # see https://www.talos.dev/v1.10/reference/configuration/v1alpha1/config/#Config.cluster.discovery
      # see https://github.com/siderolabs/talos/issues/9980
      # see https://github.com/siderolabs/talos/commit/c12b52491456d1e52204eb290d0686a317358c7c
      discovery = {
        enabled = false
        registries = {
          kubernetes = {
            disabled = true
          }
          service = {
            disabled = true
          }
        }
      }
      network = {
        cni = {
          name = "none"
        }
      }
      proxy = {
        disabled = true
      }
    }
  }
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/resources/machine_secrets
resource "talos_machine_secrets" "talos" {
  talos_version = "v${var.talos_version}"
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/data-sources/machine_configuration
data "talos_machine_configuration" "controller" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "controlplane"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
    yamlencode({
      machine = {
        network = {
          interfaces = [
            # see https://www.talos.dev/v1.10/talos-guides/network/vip/
            {
              interface = "eth0"
              dhcp      = true
              vip = {
                ip = var.cluster_vip
              }
            }
          ]
        }
      }
    }),
    yamlencode({
      cluster = {
        inlineManifests = [
          {
            name     = "spin"
            contents = <<-EOF
            apiVersion: node.k8s.io/v1
            kind: RuntimeClass
            metadata:
              name: wasmtime-spin-v2
            handler: spin
            EOF
          },
          {
            name = "cilium"
            contents = join("---\n", [
              data.helm_template.cilium.manifest,
              "# Source cilium.tf\n${local.cilium_external_lb_manifest}",
            ])
          },
          {
            name = "cert-manager"
            contents = join("---\n", [
              yamlencode({
                apiVersion = "v1"
                kind       = "Namespace"
                metadata = {
                  name = "cert-manager"
                }
              }),
              data.helm_template.cert_manager.manifest,
              "# Source cert-manager.tf\n${local.cert_manager_ingress_ca_manifest}",
            ])
          },
          {
            name     = "trust-manager"
            contents = data.helm_template.trust_manager.manifest
          },
          {
            name     = "reloader"
            contents = data.helm_template.reloader.manifest
          },
          {
            name     = "zot"
            contents = local.zot_manifest
          },
          {
            name     = "gitea"
            contents = local.gitea_manifest
          },
          {
            name = "argocd"
            contents = join("---\n", [
              yamlencode({
                apiVersion = "v1"
                kind       = "Namespace"
                metadata = {
                  name = local.argocd_namespace
                }
              }),
              data.helm_template.argocd.manifest,
              "# Source argocd.tf\n${local.argocd_manifest}",
            ])
          },
        ],
      },
    }),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/data-sources/machine_configuration
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "worker"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/data-sources/client_configuration
data "talos_client_configuration" "talos" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoints            = [for node in local.controller_nodes : node.address]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/resources/cluster_kubeconfig
resource "talos_cluster_kubeconfig" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_bootstrap.talos,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/resources/machine_configuration_apply
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

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/resources/machine_configuration_apply
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

// see https://registry.terraform.io/providers/siderolabs/talos/0.8.1/docs/resources/machine_bootstrap
resource "talos_machine_bootstrap" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_configuration_apply.controller,
  ]
}
