# see https://en.wikipedia.org/wiki/MAC_address#Ranges_of_group_and_locally_administered_addresses
locals {
  controller_nodes = [
    for i in range(var.controller_count) : {
      name    = "c${i}"
      mac     = format("02:00:00:00:01:%02x", var.cluster_node_network_first_controller_hostnum + i)
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_controller_hostnum + i)
    }
  ]
  worker_nodes = [
    for i in range(var.worker_count) : {
      name    = "w${i}"
      mac     = format("02:00:00:00:01:%02x", var.cluster_node_network_first_worker_hostnum + i)
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_worker_hostnum + i)
    }
  ]
  kube_prism_port = 7445
  common_machine_configs = [
    // see https://docs.siderolabs.com/kubernetes-guides/advanced-guides/kubeprism
    // see https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/kubeprism
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeprismconfig
    // see talosctl -n $c0 read /etc/kubernetes/kubeconfig-kubelet | yq .clusters[].cluster.server
    // NB if you use a non-default CNI, you must configure it to use the
    //      https://localhost:7445 kube-apiserver endpoint.
    {
      apiVersion = "v1alpha1"
      kind       = "KubePrismConfig"
      port       = local.kube_prism_port
    },
    // disable kubernetes discovery as its no longer compatible with k8s 1.32+.
    // NB we actually disable the discovery altogether, at the other discovery
    //    mechanism, service discovery, requires the public discovery service
    //    from https://discovery.talos.dev/ (or a custom and paid one running
    //    locally in your network).
    // NB without this, talosctl get members, always returns an empty set.
    // see https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/discovery
    // see https://github.com/siderolabs/talos/issues/9980
    // see https://github.com/siderolabs/talos/commit/c12b52491456d1e52204eb290d0686a317358c7c
    {
      apiVersion = "v1alpha1"
      kind       = "DiscoveryServiceConfig"
      "$patch"   = "delete"
    },
    // add the piraeus kernel module dependencies.
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/runtime/kernelmoduleconfig
    {
      apiVersion = "v1alpha1"
      kind       = "KernelModuleConfig"
      name       = "drbd"
      parameters = [
        "usermode_helper=disabled",
      ]
    },
    {
      apiVersion = "v1alpha1"
      kind       = "KernelModuleConfig"
      name       = "drbd_transport_tcp"
    },
    // disable the default Talos Flannel CNI (we are using Cilium instead).
    // NB this is used in tandem with the control plane configuration, which also disables kube-proxy.
    // see https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#without-kube-proxy
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeflannelcniconfig
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeproxyconfig
    {
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      "$patch"   = "delete"
    },
    // disable forwardKubeDNSToHost as its incompatible with Cilium.
    // see https://docs.siderolabs.com/talos/v1.14/networking/host-dns
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/resolverconfig
    {
      apiVersion = "v1alpha1"
      kind       = "ResolverConfig"
      hostDNS = {
        enabled              = true
        forwardKubeDNSToHost = false
      }
    },
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/statichostconfig
    // see talosctl -n $c0 read /etc/hosts
    {
      apiVersion = "v1alpha1"
      kind       = "StaticHostConfig"
      name       = local.zot_cluster_ip
      hostnames = [
        local.zot_cluster_domain,
      ]
    },
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/cri/registryauthconfig
    // see talosctl -n $c0 read /etc/cri/conf.d/cri.toml
    {
      apiVersion = "v1alpha1"
      kind       = "RegistryAuthConfig"
      name       = local.zot_cluster_host
      username   = "talos"
      password   = "talos"
    },
    // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/cri/registrymirrorconfig
    // see talosctl -n $c0 read /etc/cri/conf.d/hosts/zot.zot.svc.cluster.local_5000_/hosts.toml
    {
      apiVersion   = "v1alpha1"
      kind         = "RegistryMirrorConfig"
      name         = local.zot_cluster_host
      endpoints    = [{ url = local.zot_cluster_url }]
      skipFallback = false
    },
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine_secrets
resource "talos_machine_secrets" "talos" {
  talos_version = "v${var.talos_version}"
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/data-sources/machine_configuration
data "talos_machine_configuration" "controller" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "controlplane"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = concat(
    [for c in local.common_machine_configs : yamlencode(c)],
    [
      // disable kube-proxy (we are using Cilium instead).
      // NB this is used in tandem with the common_machine_configs above, which also disables the flannel CNI.
      // see https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#without-kube-proxy
      // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeflannelcniconfig
      // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeproxyconfig
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeProxyConfig"
        enabled    = false
      }),
      // see https://docs.siderolabs.com/talos/v1.14/networking/advanced/vip
      // see https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/layer2vipconfig
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "Layer2VIPConfig"
        link       = "eth0"
        name       = var.cluster_vip
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "spin"
        manifest   = <<-EOF
          apiVersion: node.k8s.io/v1
          kind: RuntimeClass
          metadata:
            name: wasmtime-spin-v2
          handler: spin
          EOF
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "cilium"
        manifest = join("---\n", [
          data.helm_template.cilium.manifest,
          "# Source cilium.tf\n${local.cilium_external_lb_manifest}",
        ])
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "cert-manager"
        manifest = join("---\n", [
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
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "trust-manager"
        manifest   = data.helm_template.trust_manager.manifest
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "reloader"
        manifest   = data.helm_template.reloader.manifest
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "zot"
        manifest   = local.zot_manifest
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "gitea"
        manifest   = local.gitea_manifest
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "argocd"
        manifest = join("---\n", [
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
      }),
    ],
  )
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/data-sources/machine_configuration
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "worker"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches     = [for c in local.common_machine_configs : yamlencode(c)]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/data-sources/client_configuration
data "talos_client_configuration" "talos" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoints            = [for node in local.controller_nodes : node.address]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/cluster_kubeconfig
resource "talos_cluster_kubeconfig" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_bootstrap.talos,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "controller" {
  count                       = var.controller_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controller.machine_configuration
  endpoint                    = local.controller_nodes[count.index].address
  node                        = local.controller_nodes[count.index].address
  config_patches = [
    # see https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/hostnameconfig
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = local.controller_nodes[count.index].name
    }),
  ]
  depends_on = [
    libvirt_domain.controller,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = local.worker_nodes[count.index].address
  node                        = local.worker_nodes[count.index].address
  config_patches = [
    # see https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/hostnameconfig
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = local.worker_nodes[count.index].name
    }),
  ]
  depends_on = [
    libvirt_domain.worker,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine_bootstrap
resource "talos_machine_bootstrap" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_configuration_apply.controller,
  ]
}
