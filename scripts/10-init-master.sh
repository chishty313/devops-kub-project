#!/usr/bin/env bash
#
# Initialise the FIRST control-plane node of an HA kubeadm cluster.
#
# Steps:
#   1. Drop a kube-vip static pod manifest in /etc/kubernetes/manifests/
#      so the kubelet brings up the HA VIP *before* kubeadm init starts
#      probing the apiserver endpoint.
#   2. kubeadm init  --control-plane-endpoint=<VIP>:6443  --upload-certs
#      so additional CPs can join with --certificate-key.
#   3. Install Calico CNI.
#   4. Print the join commands for control-plane nodes AND workers.
#
# Run on cp1 (the bootstrap CP). Other CPs use scripts/15-join-control-plane.sh,
# workers use scripts/20-join-worker.sh.
#
# Required env vars (set them before invoking via sudo):
#   POD_CIDR           default 192.168.0.0/16   (Calico expects this)
#   ADVERTISE_ADDR     this node's primary IP   (auto-detected if unset)
#   CONTROL_PLANE_VIP  the floating IP kube-vip will hold (must be on
#                      the same L2 as cp1/cp2/cp3 — pick an unused
#                      address on the multipass bridge, e.g. 10.x.x.250)
#   KUBE_VIP_VERSION   default v0.8.0
#

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
ADVERTISE_ADDR="${ADVERTISE_ADDR:-$(hostname -I | awk '{print $1}')}"
CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:-}"
KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v0.8.0}"
KUBE_VIP_INTERFACE="${KUBE_VIP_INTERFACE:-$(ip route get 8.8.8.8 | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}')}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"

if [[ -z "${CONTROL_PLANE_VIP}" ]]; then
    echo "ERROR: CONTROL_PLANE_VIP must be set (the kube-vip floating IP)."
    echo "Pick an unused address on the multipass bridge, e.g. 10.x.x.250."
    exit 1
fi

echo "[init-master] POD_CIDR           = ${POD_CIDR}"
echo "[init-master] ADVERTISE_ADDR     = ${ADVERTISE_ADDR}"
echo "[init-master] CONTROL_PLANE_VIP  = ${CONTROL_PLANE_VIP}"
echo "[init-master] KUBE_VIP_INTERFACE = ${KUBE_VIP_INTERFACE}"

# ---- Step 1: kube-vip static pod manifest ----
echo "[init-master] Generating kube-vip static pod manifest ..."
mkdir -p /etc/kubernetes/manifests
ctr image pull "ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}" >/dev/null
ctr run --rm --net-host \
    "ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}" vip /kube-vip manifest pod \
    --interface "${KUBE_VIP_INTERFACE}" \
    --address   "${CONTROL_PLANE_VIP}" \
    --controlplane \
    --arp \
    --leaderElection \
    >/etc/kubernetes/manifests/kube-vip.yaml

# kube-vip needs the admin kubeconfig path set BEFORE kubeadm init
# (chicken-and-egg fix from kube-vip docs):
sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#g' \
    /etc/kubernetes/manifests/kube-vip.yaml

# ---- Step 2: kubeadm init ----
echo "[init-master] Pulling control-plane images ..."
kubeadm config images pull

echo "[init-master] Running kubeadm init ..."
kubeadm init \
    --apiserver-advertise-address="${ADVERTISE_ADDR}" \
    --control-plane-endpoint="${CONTROL_PLANE_VIP}:6443" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name="${NODE_NAME}" \
    --upload-certs

# Restore kube-vip path (init creates super-admin.conf, then we want admin.conf)
sed -i 's#path: /etc/kubernetes/super-admin.conf#path: /etc/kubernetes/admin.conf#g' \
    /etc/kubernetes/manifests/kube-vip.yaml

# ---- Step 3: kubeconfig for the invoking user ----
TARGET_HOME="${SUDO_USER:+/home/${SUDO_USER}}"
TARGET_HOME="${TARGET_HOME:-/root}"
mkdir -p "${TARGET_HOME}/.kube" /root/.kube
cp -f /etc/kubernetes/admin.conf "${TARGET_HOME}/.kube/config"
cp -f /etc/kubernetes/admin.conf /root/.kube/config
[[ -n "${SUDO_USER:-}" ]] && chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_HOME}/.kube"

# ---- Step 4: Calico CNI ----
# IMPORTANT: must use --server-side --force-conflicts because the Tigera
# operator's `installations.operator.tigera.io` CRD ships with very large
# embedded OpenAPI schema annotations. Plain `kubectl apply -f` stuffs the
# whole manifest into kubectl.kubernetes.io/last-applied-configuration,
# which doubles the size and trips the 262144-byte annotation limit.
# Server-Side Apply doesn't write that annotation, so the CRD goes through.
echo "[init-master] Installing Calico CNI (server-side apply) ..."
KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply --server-side --force-conflicts -f \
    https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

cat <<EOF >/tmp/calico-installation.yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
EOF
KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply --server-side --force-conflicts -f /tmp/calico-installation.yaml

# ---- Step 5: Save join commands for the other CPs and the workers ----
echo "[init-master] Generating join commands ..."
WORKER_JOIN="$(kubeadm token create --print-join-command)"
CERT_KEY="$(kubeadm init phase upload-certs --upload-certs 2>&1 | tail -n1 | tr -d '\r')"

cat >/root/kubeadm-join-cp.sh <<EOF
#!/usr/bin/env bash
# Join an additional control-plane node. Run as root.
set -euo pipefail
${WORKER_JOIN} \\
    --control-plane \\
    --certificate-key ${CERT_KEY}
EOF
chmod 755 /root/kubeadm-join-cp.sh

cat >/root/kubeadm-join-worker.sh <<EOF
#!/usr/bin/env bash
# Join a worker node. Run as root.
set -euo pipefail
${WORKER_JOIN}
EOF
chmod 755 /root/kubeadm-join-worker.sh

echo
echo "[init-master] DONE."
echo "  Control-plane join script: /root/kubeadm-join-cp.sh"
echo "  Worker join script:        /root/kubeadm-join-worker.sh"
echo
echo "  KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide"
KUBECONFIG=/etc/kubernetes/admin.conf kubectl wait --for=condition=Ready node --all --timeout=300s || true
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A
