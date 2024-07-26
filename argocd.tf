locals {
  argocd_domain = "argocd.${var.ingress_domain}"
  argocd_manifests = [
    # create the argocd-server tls secret.
    # NB argocd-server will automatically reload this secret.
    # NB alternatively we could set the server.certificate.enabled helm value. but
    #    that does not allow us to fully customize the certificate (e.g. subject).
    # see https://github.com/argoproj/argo-helm/blob/argo-cd-7.3.11/charts/argo-cd/templates/argocd-server/certificate.yaml
    # see https://argo-cd.readthedocs.io/en/stable/operator-manual/tls/
    # see https://cert-manager.io/docs/reference/api-docs/#cert-manager.io/v1.Certificate
    {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "argocd-server"
        namespace = "argocd"
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
        commonName = "ArgoCD Server"
        dnsNames = [
          local.argocd_domain,
          "argocd-dex-server",
          "argocd-dex-server.argocd.svc",
        ]
        privateKey = {
          algorithm = "ECDSA" # NB Ed25519 is not yet supported by chrome 93 or firefox 91.
          size      = 256
        }
        duration   = "4320h" # NB 4320h (180 days). default is 2160h (90 days).
        secretName = "argocd-server-tls"
        issuerRef = {
          kind = "ClusterIssuer"
          name = "ingress"
        }
      }
    },
  ]
  argocd_manifest = join("---\n", [for d in local.argocd_manifests : yamlencode(d)])
}

# set the configuration.
# NB the default values are described at:
#       https://github.com/argoproj/argo-helm/blob/argo-cd-7.3.11/charts/argo-cd/values.yaml
#    NB make sure you are seeing the same version of the chart that you are installing.
# see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "argocd" {
  namespace  = "argocd"
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # see https://artifacthub.io/packages/helm/argo/argo-cd
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  version      = "7.3.11"
  kube_version = var.kubernetes_version
  api_versions = []
  set {
    name  = "global.domain"
    value = local.argocd_domain
  }
  set {
    name  = "server.ingress.enabled"
    value = "true"
  }
  set {
    name  = "server.ingress.tls"
    value = "true"
  }
  set_list {
    name  = "server.extraArgs"
    value = ["--insecure"]
  }
  set_list {
    name  = "repoServer.extraArgs"
    value = ["--disable-tls"]
  }
  set_list {
    name  = "dex.extraArgs"
    value = ["--disable-tls"]
  }
}
