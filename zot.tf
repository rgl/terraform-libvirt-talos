locals {
  zot_domain         = "zot.${var.ingress_domain}"
  zot_cluster_domain = "zot.${local.zot_namespace}.svc.cluster.local"
  zot_cluster_ip     = "10.96.0.20"
  zot_cluster_host   = "${local.zot_cluster_domain}:5000"
  zot_cluster_url    = "http://${local.zot_cluster_host}"
  zot_namespace      = "zot"
  zot_manifests = [
    {
      apiVersion = "v1"
      kind       = "Namespace"
      metadata = {
        name = local.zot_namespace
      }
    },
    # create the zot tls secret.
    # see https://cert-manager.io/docs/reference/api-docs/#cert-manager.io/v1.Certificate
    {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "zot"
        namespace = local.zot_namespace
      }
      spec = {
        subject = {
          organizations = [
            var.ingress_domain,
          ]
          organizationalUnits = [
            "Kubernetes",
          ]
        }
        commonName = "Zot"
        dnsNames = [
          local.zot_domain,
        ]
        privateKey = {
          algorithm = "ECDSA" # NB Ed25519 is not yet supported by chrome 93 or firefox 91.
          size      = 256
        }
        duration   = "4320h" # NB 4320h (180 days). default is 2160h (90 days).
        secretName = "zot-tls"
        issuerRef = {
          kind = "ClusterIssuer"
          name = "ingress"
        }
      }
    },
  ]
  zot_manifest = join("---\n", [data.kustomizer_manifest.zot.manifest], [for d in local.zot_manifests : yamlencode(d)])
}

# set the configuration.
# NB the default values are described at:
#       https://github.com/project-zot/helm-charts/tree/zot-0.1.95/charts/zot/values.yaml
#    NB make sure you are seeing the same version of the chart that you are installing.
# see https://zotregistry.dev/v2.1.13/install-guides/install-guide-k8s/
# see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "zot" {
  namespace  = local.zot_namespace
  name       = "zot"
  repository = "https://zotregistry.dev/helm-charts"
  chart      = "zot"
  # see https://artifacthub.io/packages/helm/zot/zot
  # renovate: datasource=helm depName=zot registryUrl=https://zotregistry.dev/helm-charts
  version      = "0.1.95" # app version 2.1.13.
  kube_version = var.kubernetes_version
  api_versions = []
  values = [yamlencode({
    service = {
      type      = "ClusterIP"
      clusterIP = local.zot_cluster_ip
    }
    ingress = {
      enabled   = true
      className = null
      pathtype  = "Prefix"
      hosts = [
        {
          host = local.zot_domain
          paths = [
            {
              path     = "/"
              pathType = "Prefix"
            }
          ]
        }
      ]
      tls = [
        {
          secretName = "zot-tls"
          hosts = [
            local.zot_domain,
          ]
        }
      ]
    }
    persistence = true
    pvc = {
      create           = true
      storageClassName = "linstor-lvm-r1"
      storage          = "8Gi"
    }
    mountConfig = true
    configFiles = {
      "config.json" = jsonencode({
        storage = {
          rootDirectory = "/var/lib/registry"
        }
        http = {
          address = "0.0.0.0"
          port    = "5000"
          auth = {
            htpasswd = {
              path = "/secret/htpasswd"
            }
          }
          accessControl = {
            repositories = {
              "**" = {
                policies = [{
                  users   = ["talos"]
                  actions = ["read"]
                }],
                anonymousPolicy = []
                defaultPolicy   = []
              }
            }
            adminPolicy = {
              users   = ["admin"]
              actions = ["read", "create", "update", "delete"]
            }
          }
        }
        log = {
          level = "debug"
        }
        extensions = {
          ui = {
            enable = true
          }
          search = {
            enable = true
            cve = {
              updateInterval = "2h"
            }
          }
        }
      })
    }
    mountSecret = true
    secretFiles = {
      # htpasswd user:pass pairs:
      #   admin:admin
      #   talos:talos
      # create a pair with:
      #   echo "talos:$(python3 -c 'import bcrypt;print(bcrypt.hashpw("talos".encode(), bcrypt.gensalt()).decode())')"
      # NB the pass value is computed as bcrypt(pass).
      htpasswd = <<-EOF
        admin:$2y$05$vmiurPmJvHylk78HHFWuruFFVePlit9rZWGA/FbZfTEmNRneGJtha
        talos:$2b$12$5nolGXPDH09gv7mGwsEpJOJx5SZj8w8y/Qt3X33wZJDnCdRs6y1Zm
        EOF
    }
    authHeader = base64encode("talos:talos")
  })]
}

# NB we mainly use the Kustomization to set the zot namespace (because the
#    helm chart cannot do it).
#    see https://github.com/project-zot/helm-charts/issues/46
# see https://registry.terraform.io/providers/rgl/kustomizer/latest/docs/data-sources/manifest
data "kustomizer_manifest" "zot" {
  files = {
    "kustomization.yaml"       = <<-EOF
      apiVersion: kustomize.config.k8s.io/v1beta1
      kind: Kustomization
      namespace: ${yamlencode(local.zot_namespace)}
      resources:
        - resources/resources.yaml
    EOF
    "resources/resources.yaml" = data.helm_template.zot.manifest
  }
}
