#!/usr/bin/env bash
#
# Join a worker node (w1 or w2) to the cluster.
# Run AFTER scripts/00-prereqs.sh succeeded on this same node.
#
# Workflow (run from the HOST):
#   multipass exec cp1 -- sudo cat /root/kubeadm-join-worker.sh > /tmp/w.sh
#   multipass transfer /tmp/w.sh w1:/tmp/kubeadm-join-worker.sh
#   multipass exec w1 -- sudo bash scripts/20-join-worker.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

modprobe overlay || true
modprobe br_netfilter || true
swapoff -a || true

if [[ ! -f /tmp/kubeadm-join-worker.sh ]]; then
    cat <<'EOM'
ERROR: /tmp/kubeadm-join-worker.sh not found.
On cp1:    sudo cat /root/kubeadm-join-worker.sh
On host:   multipass exec cp1 -- sudo cat /root/kubeadm-join-worker.sh > /tmp/w.sh
           multipass transfer /tmp/w.sh <worker-name>:/tmp/kubeadm-join-worker.sh
EOM
    exit 1
fi

bash /tmp/kubeadm-join-worker.sh

echo
echo "[join-worker] DONE on $(hostname). From cp1, verify:"
echo "  kubectl get nodes -o wide"
