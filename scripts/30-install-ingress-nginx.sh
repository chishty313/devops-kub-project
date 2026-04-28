#!/usr/bin/env bash
#
# Install ingress-nginx via Helm using k8s/ingress-nginx-values.yaml.
# Run on the control-plane (where kubectl/helm have access).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v helm >/dev/null 2>&1; then
    echo "[ingress] Installing helm 3 ..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    -f "${ROOT}/k8s/ingress-nginx-values.yaml" \
    --wait --timeout 5m

kubectl -n ingress-nginx get pods -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller
echo
echo "[ingress] ingress-nginx is now reachable on:"
echo "  http://<NODE_IP>:30080   (NodePort)"
echo "  https://<NODE_IP>:30443  (NodePort)"
echo
echo "[ingress] Next: on the host, run scripts/25-setup-host-nginx.sh to wire"
echo "          the public 80/443 ports through to the worker NodePorts."
