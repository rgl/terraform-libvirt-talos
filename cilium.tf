locals {
  # see https://docs.cilium.io/en/stable/network/lb-ipam/
  # see https://docs.cilium.io/en/stable/network/l2-announcements/
  # see the CiliumL2AnnouncementPolicy type at https://github.com/cilium/cilium/blob/v1.14.5/pkg/k8s/apis/cilium.io/v2alpha1/l2announcement_types.go#L20-L39
  # see the CiliumLoadBalancerIPPool type at https://github.com/cilium/cilium/blob/v1.14.5/pkg/k8s/apis/cilium.io/v2alpha1/lbipam_types.go#L23-L47
  cilium_external_lb_manifests = [
    {
      apiVersion = "cilium.io/v2alpha1"
      kind       = "CiliumL2AnnouncementPolicy"
      metadata = {
        name = "external"
      }
      spec = {
        loadBalancerIPs = true
        interfaces = [
          "eth0",
        ]
        nodeSelector = {
          matchExpressions = [
            {
              key      = "node-role.kubernetes.io/control-plane"
              operator = "DoesNotExist"
            },
          ]
        }
      }
    },
    {
      apiVersion = "cilium.io/v2alpha1"
      kind       = "CiliumLoadBalancerIPPool"
      metadata = {
        name = "external"
      }
      spec = {
        cidrs = [
          # TODO once https://github.com/cilium/cilium/pull/26488 lands in a
          #      release, use a range instead, which is easier to use in a
          #      adhoc network.
          {
            cidr = "${var.cluster_node_network_prefix}.128/25" # e.g. 10.17.3.129..254.
          },
        ]
      }
    },
  ]
  cilium_external_lb_manifest = join("---\n", [for d in local.cilium_external_lb_manifests : yamlencode(d)])
}

// see https://www.talos.dev/v1.6/kubernetes-guides/network/deploying-cilium/#method-4-helm-manifests-inline-install
// see https://docs.cilium.io/en/stable/network/servicemesh/ingress/
// see https://docs.cilium.io/en/stable/gettingstarted/hubble_setup/
// see https://docs.cilium.io/en/stable/gettingstarted/hubble/
// see https://docs.cilium.io/en/stable/helm-reference/#helm-reference
// see https://github.com/cilium/cilium/releases
// see https://github.com/cilium/cilium/tree/v1.14.5/install/kubernetes/cilium
// see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "cilium" {
  namespace  = "kube-system"
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.14.5"
  set {
    name  = "ipam.mode"
    value = "kubernetes"
  }
  set {
    name  = "securityContext.capabilities.ciliumAgent"
    value = "{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  }
  set {
    name  = "securityContext.capabilities.cleanCiliumState"
    value = "{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  }
  set {
    name  = "cgroup.autoMount.enabled"
    value = "false"
  }
  set {
    name  = "cgroup.hostRoot"
    value = "/sys/fs/cgroup"
  }
  set {
    name  = "k8sServiceHost"
    value = "localhost"
  }
  set {
    name  = "k8sServicePort"
    value = local.common_machine_config.machine.features.kubePrism.port
  }
  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }
  set {
    name  = "l2announcements.enabled"
    value = "true"
  }
  set {
    name  = "devices"
    value = "{eth0}"
  }
  set {
    name  = "ingressController.enabled"
    value = "true"
  }
  set {
    name  = "ingressController.default"
    value = "true"
  }
  set {
    name  = "ingressController.loadbalancerMode"
    value = "shared"
  }
  set {
    name  = "ingressController.enforceHttps"
    value = "false"
  }
  set {
    name  = "envoy.enabled"
    value = "true"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }
}
