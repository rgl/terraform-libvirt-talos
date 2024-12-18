#!/bin/bash
set -euo pipefail

# the talos image builder.
# NB this can be one of:
#   imager: build locally using the ghcr.io/siderolabs/imager container image.
#   image_factory: build remotely using the image factory service at https://factory.talos.dev.
# NB this is automatically set to imager when running on linux 6.1+; otherwise,
#    it is set to image_factory.
talos_image_builder="$(perl -e 'print ((`uname -r` =~ /^(\d+\.\d+)/ && $1 >= 6.1) ? "imager" : "image_factory")')"

# see https://github.com/siderolabs/talos/releases
# renovate: datasource=github-releases depName=siderolabs/talos
talos_version="1.9.0"

# see https://github.com/siderolabs/extensions/pkgs/container/qemu-guest-agent
# see https://github.com/siderolabs/extensions/tree/main/guest-agents/qemu-guest-agent
talos_qemu_guest_agent_extension_tag="9.1.2@sha256:a849e55254f1cd8669ab742cdcfee200aada3dfe320841af3c338dc7cec956e9"

# see https://github.com/siderolabs/extensions/pkgs/container/drbd
# see https://github.com/siderolabs/extensions/tree/main/storage/drbd
# see https://github.com/LINBIT/drbd
talos_drbd_extension_tag="9.2.12-v1.9.0@sha256:209feb3c3bb5ae3a1f43b5ec9dd55be77f958dccecc3ec39d361b4f35fde3f6c"

# see https://github.com/siderolabs/extensions/pkgs/container/spin
# see https://github.com/siderolabs/extensions/tree/main/container-runtime/spin
talos_spin_extension_tag="v0.17.0@sha256:3f4cc5278d3b50b472e25e075688b1eb274e8e3f648bd25f969628bc2d69b1e1"

# see https://github.com/piraeusdatastore/piraeus-operator/releases
# renovate: datasource=github-releases depName=piraeusdatastore/piraeus-operator
piraeus_operator_version="2.7.1"

export CHECKPOINT_DISABLE='1'
export TF_LOG='DEBUG' # TRACE, DEBUG, INFO, WARN or ERROR.
export TF_LOG_PATH='terraform.log'

export TALOSCONFIG=$PWD/talosconfig.yml
export KUBECONFIG=$PWD/kubeconfig.yml

function step {
  echo "### $* ###"
}

function update-talos-extension {
  # see https://github.com/siderolabs/extensions?tab=readme-ov-file#installing-extensions
  local variable_name="$1"
  local image_name="$2"
  local images="$3"
  local image="$(grep -F "$image_name:" <<<"$images")"
  local tag="${image#*:}"
  echo "updating the talos extension to $image..."
  variable_name="$variable_name" tag="$tag" perl -i -pe '
    BEGIN {
      $var = $ENV{variable_name};
      $val = $ENV{tag};
    }
    s/^(\Q$var\E=).*/$1"$val"/;
  ' do
}

function update-talos-extensions {
  step "updating the talos extensions"
  local images="$(crane export "ghcr.io/siderolabs/extensions:v$talos_version" | tar x -O image-digests)"
  update-talos-extension talos_qemu_guest_agent_extension_tag ghcr.io/siderolabs/qemu-guest-agent "$images"
  update-talos-extension talos_drbd_extension_tag ghcr.io/siderolabs/drbd "$images"
  update-talos-extension talos_spin_extension_tag ghcr.io/siderolabs/spin "$images"
}

function build_talos_image__imager {
  # see https://www.talos.dev/v1.9/talos-guides/install/boot-assets/
  # see https://www.talos.dev/v1.9/advanced/metal-network-configuration/
  # see Profile type at https://github.com/siderolabs/talos/blob/v1.9.0/pkg/imager/profile/profile.go#L24-L47
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
    - imageRef: ghcr.io/siderolabs/qemu-guest-agent:$talos_qemu_guest_agent_extension_tag
    - imageRef: ghcr.io/siderolabs/drbd:$talos_drbd_extension_tag
    - imageRef: ghcr.io/siderolabs/spin:$talos_spin_extension_tag
output:
  kind: image
  imageOptions:
    diskSize: $((2*1024*1024*1024))
    diskFormat: raw
  outFormat: raw
EOF
  echo "creating image..."
  docker run --rm -i \
    -v $PWD/tmp/talos:/secureboot:ro \
    -v $PWD/tmp/talos:/out \
    -v /dev:/dev \
    --privileged \
    "ghcr.io/siderolabs/imager:$talos_version_tag" \
    - < "tmp/talos/talos-$talos_version.yml"
}

function build_talos_image__image_factory {
  # see https://www.talos.dev/v1.9/learn-more/image-factory/
  # see https://github.com/siderolabs/image-factory?tab=readme-ov-file#http-frontend-api
  local talos_version_tag="v$talos_version"
  rm -rf tmp/talos
  mkdir -p tmp/talos
  echo "creating image factory schematic..."
  cat >"tmp/talos/talos-$talos_version.yml" <<EOF
customization:
  extraKernelArgs:
    - net.ifnames=0
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/drbd
      - siderolabs/spin
EOF
  local schematic_response="$(curl \
    -X POST \
    --silent \
    --data-binary @"tmp/talos/talos-$talos_version.yml" \
    https://factory.talos.dev/schematics)"
  local schematic_id="$(jq -r .id <<<"$schematic_response")"
  if [ -z "$schematic_id" ]; then
    echo "ERROR: Failed to create the image schematic."
    exit 1
  fi
  local image_url="https://factory.talos.dev/image/$schematic_id/$talos_version_tag/nocloud-amd64.raw.zst"
  echo "downloading image from $image_url..."
  rm -f tmp/talos/nocloud-amd64.raw.zst
  curl \
    --silent \
    --output tmp/talos/nocloud-amd64.raw.zst \
    "$image_url"
  echo "extracting image..."
  unzstd tmp/talos/nocloud-amd64.raw.zst
}

function build_talos_image {
  case "$talos_image_builder" in
    imager)
      build_talos_image__imager
      ;;
    image_factory)
      build_talos_image__image_factory
      ;;
    *)
      echo $"unknown talos_image_builder $talos_image_builder"
      exit 1
      ;;
  esac
  echo "converting image to the qcow2 format..."
  local talos_libvirt_base_volume_name="talos-$talos_version.qcow2"
  qemu-img convert -O qcow2 tmp/talos/nocloud-amd64.raw tmp/talos/$talos_libvirt_base_volume_name
  qemu-img info tmp/talos/$talos_libvirt_base_volume_name
  if [ -n "$(virsh vol-list default | grep $talos_libvirt_base_volume_name)" ]; then
    virsh vol-delete --pool default $talos_libvirt_base_volume_name
  fi
  echo "uploading image to libvirt..."
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
  piraeus-install
  export-kubernetes-ingress-ca-crt
  info
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
}

function piraeus-install {
  # see https://github.com/piraeusdatastore/piraeus-operator
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/how-to/talos.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/tutorial/get-started.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/tutorial/replicated-volumes.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/explanation/components.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/reference/linstorsatelliteconfiguration.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/reference/linstorcluster.md
  # see https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/
  # see https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/#ch-kubernetes
  # see 5.7.1. Available Parameters in a Storage Class at https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/#s-kubernetes-sc-parameters
  # see https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
  # see https://www.talos.dev/v1.9/kubernetes-guides/configuration/storage/#piraeus--linstor
  step 'piraeus install'
  kubectl apply --server-side -k "https://github.com/piraeusdatastore/piraeus-operator//config/default?ref=v$piraeus_operator_version"
  step 'piraeus wait'
  kubectl wait pod --timeout=15m --for=condition=Ready -n piraeus-datastore -l app.kubernetes.io/component=piraeus-operator
  step 'piraeus configure'
  kubectl apply -n piraeus-datastore -f - <<'EOF'
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: talos-loader-override
spec:
  podTemplate:
    spec:
      initContainers:
        - name: drbd-shutdown-guard
          $patch: delete
        - name: drbd-module-loader
          $patch: delete
      volumes:
        - name: run-systemd-system
          $patch: delete
        - name: run-drbd-shutdown-guard
          $patch: delete
        - name: systemd-bus-socket
          $patch: delete
        - name: lib-modules
          $patch: delete
        - name: usr-src
          $patch: delete
        - name: etc-lvm-backup
          hostPath:
            path: /var/etc/lvm/backup
            type: DirectoryOrCreate
        - name: etc-lvm-archive
          hostPath:
            path: /var/etc/lvm/archive
            type: DirectoryOrCreate
EOF
  kubectl apply -f - <<EOF
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
EOF
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
provisioner: linstor.csi.linbit.com
metadata:
  name: linstor-lvm-r1
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  csi.storage.k8s.io/fstype: xfs
  linstor.csi.linbit.com/autoPlace: "1"
  linstor.csi.linbit.com/storagePool: lvm
EOF
  step 'piraeus configure wait'
  kubectl wait pod --timeout=15m --for=condition=Ready -n piraeus-datastore -l app.kubernetes.io/name=piraeus-datastore
  kubectl wait LinstorCluster/linstor --timeout=15m --for=condition=Available
  step 'piraeus create-device-pool'
  local workers="$(terraform output -raw workers)"
  local nodes=($(echo "$workers" | tr ',' ' '))
  for ((n=0; n<${#nodes[@]}; ++n)); do
    local node="w$((n))"
    local wwn="$(printf "000000000000ab%02x" $n)"
    step "piraeus wait node $node"
    while ! kubectl linstor storage-pool list --node "$node" >/dev/null 2>&1; do sleep 3; done
    step "piraeus create-device-pool $node"
    if ! kubectl linstor storage-pool list --node "$node" --storage-pool lvm | grep -q lvm; then
      kubectl linstor physical-storage create-device-pool \
        --pool-name lvm \
        --storage-pool lvm \
        lvm \
        "$node" \
        "/dev/disk/by-id/wwn-0x$wwn"
    fi
  done
}

function piraeus-info {
  step 'piraeus node list'
  kubectl linstor node list
  step 'piraeus storage-pool list'
  kubectl linstor storage-pool list
  step 'piraeus volume list'
  kubectl linstor volume list
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
      | jq -r 'select(.metadata.id | test("v\\d+")) | .spec' \
      | yq -r '.machine.install.image' \
      | sed -E "s,(.+),$n: \1,g"
  done
  step 'talos node os-release'
  for n in "${nodes[@]}"; do
    talosctl -n $n read /etc/os-release \
      | sed -E "s,(.+),$n: \1,g"
  done
  step 'kubernetes nodes'
  kubectl get nodes -o wide
  piraeus-info
}

function export-kubernetes-ingress-ca-crt {
  kubectl get -n cert-manager secret/ingress-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d \
    > kubernetes-ingress-ca-crt.pem
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
  update-talos-extensions)
    update-talos-extensions
    ;;
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
