#!/usr/bin/env bash
#
# Install Argo CD + an Ingress for argocd.chishty.me.
# Then apply the Application manifest under k8s/argocd-application.yaml so
# the Laravel deployment is managed via GitOps.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

echo "[argocd] Installing chart ..."
# server.ingress.tls=true already creates a TLS spec with secretName
# 'argocd-server-tls'. We deliberately do NOT also pass extraTls — that
# would render TWO TLS entries for the same hostname, and cert-manager
# would issue TWO certificates that fight over the same HTTP-01 path.
# configs.params.'server.insecure'=true makes argocd-server speak HTTP
# inside the cluster so ingress-nginx terminates TLS with the cert.
helm upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --version 7.6.12 \
    --set configs.params."server\.insecure"=true \
    --set server.ingress.enabled=true \
    --set server.ingress.ingressClassName=nginx \
    --set server.ingress.hostname=argocd.chishty.me \
    --set server.ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-prod \
    --set server.ingress.tls=true \
    --wait --timeout 10m

echo
echo "[argocd] Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
echo
echo "[argocd] UI: https://argocd.chishty.me  (user: admin)"
echo

echo "[argocd] Applying Application manifest (laravel-k8s) ..."
kubectl apply -n argocd -f "${ROOT}/k8s/argocd-application.yaml"

kubectl -n argocd get applications
