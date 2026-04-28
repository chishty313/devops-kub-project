#!/usr/bin/env bash
#
# Join an additional control-plane node (cp2 or cp3) to the cluster.
# Run AFTER scripts/00-prereqs.sh succeeded on this node.
#
# Workflow (run from the HOST):
#   1. Copy /root/kubeadm-join-cp.sh from cp1 to /tmp/ on this node.
#   2. Drop the kube-vip static-pod manifest BEFORE joining (so the kubelet
#      brings up the VIP locally as soon as control-plane components start).
#   3. Run the join script.
#
# Required env (auto-detected if absent):
#   CONTROL_PLANE_VIP   the floating IP shared by all CPs
#   KUBE_VIP_VERSION    default v0.8.0

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:-}"
KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v0.8.0}"
KUBE_VIP_INTERFACE="${KUBE_VIP_INTERFACE:-$(ip route get 8.8.8.8 | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}')}"

if [[ -z "${CONTROL_PLANE_VIP}" ]]; then
    echo "ERROR: CONTROL_PLANE_VIP must be set."
    exit 1
fi

if [[ ! -f /tmp/kubeadm-join-cp.sh ]]; then
    cat <<EOM
ERROR: /tmp/kubeadm-join-cp.sh not found.
On the host, run:
  multipass exec cp1 -- sudo cat /root/kubeadm-join-cp.sh > /tmp/cp.sh
  multipass transfer /tmp/cp.sh ${HOSTNAME}:/tmp/kubeadm-join-cp.sh
EOM
    exit 1
fi

# Generate the kube-vip static pod manifest BEFORE joining.
echo "[join-cp] Dropping kube-vip static pod manifest ..."
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

echo "[join-cp] Running kubeadm join ..."
bash /tmp/kubeadm-join-cp.sh

echo
echo "[join-cp] DONE on $(hostname). From cp1, verify:"
echo "  kubectl get nodes -o wide"
