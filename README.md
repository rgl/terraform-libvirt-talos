# About

An example Talos Linux Kubernetes cluster in libvirt QEMU/KVM Virtual Machines using terraform.

# Usage (Ubuntu 22.04 host)

Install Terraform:

```bash
wget https://releases.hashicorp.com/terraform/1.3.7/terraform_1.3.7_linux_amd64.zip
unzip terraform_1.3.7_linux_amd64.zip
sudo install terraform /usr/local/bin
rm terraform terraform_*_linux_amd64.zip
```

Install talosctl:

```bash
talos_version='1.3.1'
wget https://github.com/siderolabs/talos/releases/download/v$talos_version/talosctl-linux-amd64
sudo install talosctl-linux-amd64 /usr/local/bin/talosctl
rm talosctl-linux-amd64
```

Install the talos image into libvirt:

```bash
talos_version='1.3.1'
wget \
  -O talos-$talos_version-metal-amd64.tar.gz \
  https://github.com/siderolabs/talos/releases/download/v$talos_version/metal-amd64.tar.gz
tar xf talos-$talos_version-metal-amd64.tar.gz
qemu-img convert -O qcow2 disk.raw talos-$talos_version.qcow2
qemu-img info talos-$talos_version.qcow2
virsh vol-create-as default talos-$talos_version-amd64.qcow2 1G
virsh vol-upload --pool default talos-$talos_version-amd64.qcow2 talos-$talos_version.qcow2
rm -f disk.raw talos-$talos_version.qcow2 talos-$talos_version-metal-amd64.tar.gz
```

Create the infrastructure:

```bash
terraform init
terraform plan -out=tfplan
time terraform apply tfplan
```

**NB** if you have errors alike `Could not open '/var/lib/libvirt/images/terraform_talos_example_c0.img': Permission denied'` you need to reconfigure libvirt by setting `security_driver = "none"` in `/etc/libvirt/qemu.conf` and restart libvirt with `sudo systemctl restart libvirtd`.

Show talos information:

```bash
terraform output -raw talosconfig >talosconfig.yml
export TALOSCONFIG=$PWD/talosconfig.yml
c0='10.17.3.10'
talosctl -n $c0 version
talosctl -n $c0 dashboard
```

Show kubernetes information:

```bash
terraform output -raw kubeconfig >kubeconfig.yml
export KUBECONFIG=$PWD/kubeconfig.yml
kubectl cluster-info
kubectl get nodes -o wide
```

Destroy the infrastructure:

```bash
time terraform destroy -auto-approve
```

# Troubleshoot

Talos:

```bash
# see https://www.talos.dev/v1.2/advanced/troubleshooting-control-plane/
talosctl -n $c0 service etcd status
talosctl -n $c0 etcd members
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
talosctl -n $c0 list -l /sys/fs/cgroup
talosctl -n $c0 read /proc/cmdline | tr ' ' '\n'
talosctl -n $c0 read /proc/mounts | sort
talosctl -n $c0 read /etc/resolv.conf
talosctl -n $c0 read /etc/containerd/config.toml
talosctl -n $c0 read /etc/cri/containerd.toml
talosctl -n $c0 read /etc/cri/conf.d/cri.toml
talosctl -n $c0 ps
talosctl -n $c0 containers -k
```

Kubernetes:

```bash
kubectl get events --all-namespaces --watch
kubectl --namespace kube-system get events --watch
kubectl run busybox -it --rm --restart=Never --image=busybox:1.36 -- nslookup -type=a talos.dev
```
