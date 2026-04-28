#!/usr/bin/env bash
#
# Install cert-manager + Let's Encrypt ClusterIssuers.
# Run from the HOST (or anywhere with KUBECONFIG pointing at cp1).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update

echo "[cert-manager] Installing chart ..."
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --version v1.15.3 \
    --wait --timeout 5m

kubectl -n cert-manager get pods

echo "[cert-manager] Applying ClusterIssuers ..."
kubectl apply -f "${ROOT}/k8s/cert-manager-issuer.yaml"
kubectl get clusterissuer

echo
echo "[cert-manager] DONE. Useful checks:"
echo "  kubectl describe clusterissuer letsencrypt-prod"
echo "  kubectl get certificate,certificaterequest,order,challenge -A"
