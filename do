#!/bin/bash
set -euo pipefail

talos_version="1.6.4" # see https://github.com/siderolabs/talos/releases
talos_qemu_guest_agent_extension_version="8.1.3" # see https://github.com/siderolabs/extensions/pkgs/container/qemu-guest-agent

export CHECKPOINT_DISABLE='1'
export TF_LOG='DEBUG' # TRACE, DEBUG, INFO, WARN or ERROR.
export TF_LOG_PATH='terraform.log'

export TALOSCONFIG=$PWD/talosconfig.yml
export KUBECONFIG=$PWD/kubeconfig.yml

function step {
  echo "### $* ###"
}

function build_talos_image {
  # see https://www.talos.dev/v1.6/talos-guides/install/boot-assets/
  # see https://www.talos.dev/v1.6/advanced/metal-network-configuration/
  # see Profile type at https://github.com/siderolabs/talos/blob/v1.6.4/pkg/imager/profile/profile.go#L20-L41
  local talos_version_tag="v$talos_version"
  rm -rf tmp/talos
  mkdir -p tmp/talos
  cat >"tmp/talos/talos-$talos_version.yml" <<EOF
arch: amd64
platform: nocloud
secureboot: false
version: $talos_version_tag
customization:
  extraKernelArgs:
    - net.ifnames=0
input:
  kernel:
    path: /usr/install/amd64/vmlinuz
  initramfs:
    path: /usr/install/amd64/initramfs.xz
  baseInstaller:
    imageRef: ghcr.io/siderolabs/installer:$talos_version_tag
  systemExtensions:
    - imageRef: ghcr.io/siderolabs/qemu-guest-agent:$talos_qemu_guest_agent_extension_version
    # see https://github.com/siderolabs/extensions/pkgs/container/wasmedge
    # see https://github.com/siderolabs/extensions/issues/318
    - imageRef: ghcr.io/siderolabs/wasmedge@sha256:efb4ce0e6f6689fe0f876a788175c7e0b32bb012438415bc91b8dbee216fb6ec
output:
  kind: image
  imageOptions:
    diskSize: $((2*1024*1024*1024))
    diskFormat: raw
  outFormat: raw
EOF
  local talos_libvirt_base_volume_name="talos-$talos_version.qcow2"
  docker run --rm -i \
    -v $PWD/tmp/talos:/secureboot:ro \
    -v $PWD/tmp/talos:/out \
    -v /dev:/dev \
    --privileged \
    "ghcr.io/siderolabs/imager:$talos_version_tag" \
    - <<<"$(cat tmp/talos/talos-$talos_version.yml)"
  qemu-img convert -O qcow2 tmp/talos/nocloud-amd64.raw tmp/talos/$talos_libvirt_base_volume_name
  qemu-img info tmp/talos/$talos_libvirt_base_volume_name
  if [ -n "$(virsh vol-list default | grep $talos_libvirt_base_volume_name)" ]; then
    virsh vol-delete --pool default $talos_libvirt_base_volume_name
  fi
  virsh vol-create-as default $talos_libvirt_base_volume_name 10M
  virsh vol-upload --pool default $talos_libvirt_base_volume_name tmp/talos/$talos_libvirt_base_volume_name
  cat >terraform.tfvars <<EOF
talos_version                  = "$talos_version"
talos_libvirt_base_volume_name = "$talos_libvirt_base_volume_name"
EOF
}

function init {
  step 'build talos image'
  build_talos_image
  step 'terraform init'
  terraform init -lockfile=readonly
}

function plan {
  step 'terraform plan'
  terraform plan -out=tfplan
}

function apply {
  step 'terraform apply'
  terraform apply tfplan
  terraform output -raw talosconfig >talosconfig.yml
  terraform output -raw kubeconfig >kubeconfig.yml
  health
}

function health {
  step 'talosctl health'
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local c0="$(echo $controllers | cut -d , -f 1)"
  talosctl -e $c0 -n $c0 \
    health \
    --control-plane-nodes $controllers \
    --worker-nodes $workers
  info
}

function info {
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local nodes=($(echo "$controllers,$workers" | tr ',' ' '))
  step 'talos node installer image'
  for n in "${nodes[@]}"; do
    # NB there can be multiple machineconfigs in a machine. we only want to see
    #    the ones with an id that looks like a version tag.
    talosctl -n $n get machineconfigs -o json \
      | jq -r 'select(.metadata.id | test("v\\d+")) | .spec.machine.install.image' \
      | sed -E "s,(.+),$n: \1,g"
  done
  step 'talos node os-release'
  for n in "${nodes[@]}"; do
    talosctl -n $n read /etc/os-release \
      | sed -E "s,(.+),$n: \1,g"
  done
}

function upgrade {
  step 'talosctl upgrade'
  local controllers=($(terraform output -raw controllers | tr ',' ' '))
  local workers=($(terraform output -raw workers | tr ',' ' '))
  for n in "${controllers[@]}" "${workers[@]}"; do
    talosctl -e $n -n $n upgrade --preserve --wait
  done
  health
}

function destroy {
  terraform destroy -auto-approve
}

case $1 in
  init)
    init
    ;;
  plan)
    plan
    ;;
  apply)
    apply
    ;;
  plan-apply)
    plan
    apply
    ;;
  health)
    health
    ;;
  info)
    info
    ;;
  destroy)
    destroy
    ;;
  *)
    echo $"Usage: $0 {init|plan|apply|plan-apply|health|info}"
    exit 1
    ;;
esac
