#!/usr/bin/env bash
#
# Run on EVERY node (master + worker) before kubeadm.
# Idempotent: safe to re-run.
#
# Targets Ubuntu 22.04 LTS.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

K8S_VERSION="${K8S_VERSION:-v1.30}"     # apt repo channel
CONTAINERD_PAUSE_IMAGE="registry.k8s.io/pause:3.9"

echo "[prereqs] OS check"
. /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
    echo "WARNING: tested on Ubuntu, you have ${PRETTY_NAME}. Continuing anyway."
fi

echo "[prereqs] Disable swap (kubelet refuses to start with swap on)"
swapoff -a
sed -ri '/\sswap\s/s/^/#/' /etc/fstab

echo "[prereqs] Enable br_netfilter + overlay kernel modules"
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "[prereqs] sysctl for k8s networking"
cat <<EOF >/etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "[prereqs] Install containerd"
apt-get update -y
apt-get install -y ca-certificates curl gnupg apt-transport-https containerd

echo "[prereqs] containerd config (SystemdCgroup = true, sandbox image fixed)"
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i \
    -e 's/SystemdCgroup = false/SystemdCgroup = true/' \
    -e "s|sandbox_image = .*|sandbox_image = \"${CONTAINERD_PAUSE_IMAGE}\"|" \
    /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "[prereqs] Install kubeadm/kubelet/kubectl (${K8S_VERSION})"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable --now kubelet

echo "[prereqs] Done on $(hostname)."
echo "Next: run scripts/10-init-master.sh on the control plane,"
echo "      then scripts/20-join-worker.sh on each worker."
