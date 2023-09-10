# About

[![Lint](https://github.com/rgl/terraform-libvirt-talos/actions/workflows/lint.yml/badge.svg)](https://github.com/rgl/terraform-libvirt-talos/actions/workflows/lint.yml)

An example Talos Linux Kubernetes cluster in libvirt QEMU/KVM Virtual Machines using terraform.

# Usage (Ubuntu 22.04 host)

Install libvirt:

```bash
# install libvirt et al.
apt-get install -y virt-manager
# configure the security_driver to prevent errors alike (when using terraform):
#   Could not open '/var/lib/libvirt/images/terraform_talos_example_c0.img': Permission denied'
sed -i -E 's,#?(security_driver)\s*=.*,\1 = "none",g' /etc/libvirt/qemu.conf
systemctl restart libvirtd
# let the current user manage libvirtd.
# see /usr/share/polkit-1/rules.d/60-libvirt.rules
usermod -aG libvirt $USER
# restart the shell.
exit
```

Install Terraform:

```bash
wget https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip
unzip terraform_1.5.7_linux_amd64.zip
sudo install terraform /usr/local/bin
rm terraform terraform_*_linux_amd64.zip
```

Install talosctl:

```bash
talos_version='1.5.2'
wget https://github.com/siderolabs/talos/releases/download/v$talos_version/talosctl-linux-amd64
sudo install talosctl-linux-amd64 /usr/local/bin/talosctl
rm talosctl-linux-amd64
```

Install the talos image into libvirt:

```bash
talos_version='1.5.2'
wget \
  -O talos-$talos_version-nocloud-amd64.raw.xz \
  https://github.com/siderolabs/talos/releases/download/v$talos_version/nocloud-amd64.raw.xz
unxz talos-$talos_version-nocloud-amd64.raw.xz
qemu-img convert -O qcow2 talos-$talos_version-nocloud-amd64.raw talos-$talos_version.qcow2
qemu-img info talos-$talos_version.qcow2
virsh vol-create-as default talos-$talos_version-amd64.qcow2 1G
virsh vol-upload --pool default talos-$talos_version-amd64.qcow2 talos-$talos_version.qcow2
rm -f talos-$talos_version-nocloud-amd64.raw talos-$talos_version.qcow2
```

**NB** To create a customized image (e.g. with different kernel arguments), see the [Boot Assets: Creating customized Talos boot assets, disk images, ISO and installer images](https://www.talos.dev/v1.5/talos-guides/install/boot-assets/) page.

Initialize terraform:

```bash
./do init
```

Create the infrastructure:

```bash
time ./do plan-apply
```

Show talos information:

```bash
export TALOSCONFIG=$PWD/talosconfig.yml
controllers="$(terraform output -raw controllers)"
workers="$(terraform output -raw workers)"
all="$controllers,$workers"
c0="$(echo $controllers | cut -d , -f 1)"
talosctl -n $all version
talosctl -n $all dashboard
```

Show kubernetes information:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
kubectl cluster-info
kubectl get nodes -o wide
```

Destroy the infrastructure:

```bash
time ./do destroy
```

# Troubleshoot

Talos:

```bash
# see https://www.talos.dev/v1.5/advanced/troubleshooting-control-plane/
talosctl -n $c0 service ext-qemu-guest-agent status
talosctl -n $c0 service etcd status
talosctl -n $c0 etcd status
talosctl -n $c0 etcd alarm list
talosctl -n $c0 etcd members
talosctl -n $c0 get members
talosctl -n $c0 health --control-plane-nodes $controllers --worker-nodes $workers
talosctl -n $c0 dashboard
talosctl -n $c0 logs controller-runtime
talosctl -n $c0 logs kubelet
talosctl -n $c0 disks
talosctl -n $c0 mounts | sort
talosctl -n $c0 get resourcedefinitions
talosctl -n $c0 get machineconfigs -o yaml
talosctl -n $c0 get staticpods -o yaml
talosctl -n $c0 get staticpodstatus
talosctl -n $c0 get manifests
talosctl -n $c0 get services
talosctl -n $c0 get extensions
talosctl -n $c0 get addresses
talosctl -n $c0 get nodeaddresses
talosctl -n $c0 list -l -r -t f /etc
talosctl -n $c0 list -l -r -t f /system
talosctl -n $c0 list -l -r -t f /var
talosctl -n $c0 list -l -r /dev
talosctl -n $c0 list -l /sys/fs/cgroup
talosctl -n $c0 read /proc/cmdline | tr ' ' '\n'
talosctl -n $c0 read /proc/mounts | sort
talosctl -n $c0 read /etc/resolv.conf
talosctl -n $c0 read /etc/containerd/config.toml
talosctl -n $c0 read /etc/cri/containerd.toml
talosctl -n $c0 read /etc/cri/conf.d/cri.toml
talosctl -n $c0 read /etc/kubernetes/kubelet.yaml
talosctl -n $c0 read /etc/kubernetes/bootstrap-kubeconfig
talosctl -n $c0 ps
talosctl -n $c0 containers -k
```

Kubernetes:

```bash
kubectl get events --all-namespaces --watch
kubectl --namespace kube-system get events --watch
kubectl --namespace kube-system debug node/w0 --stdin --tty --image=busybox:1.36 -- cat /host/etc/resolv.conf
kubectl --namespace kube-system get configmaps coredns --output yaml
pod_name="$(kubectl --namespace kube-system get pods --selector k8s-app=kube-dns --output json | jq -r '.items[0].metadata.name')"
kubectl --namespace kube-system debug $pod_name --stdin --tty --image=busybox:1.36 --target=coredns -- sh -c 'cat /proc/$(pgrep coredns)/root/etc/resolv.conf'
kubectl --namespace kube-system run busybox -it --rm --restart=Never --image=busybox:1.36 -- nslookup -type=a talos.dev
```
