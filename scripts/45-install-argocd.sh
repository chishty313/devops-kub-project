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
helm upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --version 7.6.12 \
    --set server.extraArgs="{--insecure}" \
    --set server.ingress.enabled=true \
    --set server.ingress.ingressClassName=nginx \
    --set server.ingress.hostname=argocd.chishty.me \
    --set server.ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-prod \
    --set server.ingress.tls=true \
    --set "server.ingress.extraTls[0].hosts[0]=argocd.chishty.me" \
    --set "server.ingress.extraTls[0].secretName=argocd-tls" \
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
