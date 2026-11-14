# see https://github.com/hashicorp/terraform
terraform {
  required_version = "1.17.2"
  required_providers {
    # see https://registry.terraform.io/providers/hashicorp/random
    # see https://github.com/hashicorp/terraform-provider-random
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
    # see https://registry.terraform.io/providers/dmacvicar/libvirt
    # see https://github.com/dmacvicar/terraform-provider-libvirt
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9"
    }
    # see https://registry.terraform.io/providers/siderolabs/talos
    # see https://github.com/siderolabs/terraform-provider-talos
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
    # see https://registry.terraform.io/providers/hashicorp/helm
    # see https://github.com/hashicorp/terraform-provider-helm
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    # see https://registry.terraform.io/providers/rgl/kustomizer
    # see https://github.com/rgl/terraform-provider-kustomizer
    kustomizer = {
      source  = "rgl/kustomizer"
      version = "0.0.3"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

provider "talos" {
}
