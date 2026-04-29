#!/usr/bin/env bash
#
# Install / upgrade the laravel-k8s Helm release.
# Generates a fresh APP_KEY on first install and stores it in secrets.local.yaml
# (which is gitignored). Re-uses the existing key on subsequent upgrades.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="${RELEASE:-laravel}"
NAMESPACE="${NAMESPACE:-laravel}"
SECRETS_FILE="${ROOT}/secrets.local.yaml"
VALUES_FILE="${VALUES_FILE:-${ROOT}/helm/laravel-k8s/values.yaml}"

if [[ ! -f "${SECRETS_FILE}" ]]; then
    echo "[helm] Generating APP_KEY into ${SECRETS_FILE} (gitignored) ..."
    KEY="base64:$(openssl rand -base64 32)"
    cat >"${SECRETS_FILE}" <<EOF
# AUTO-GENERATED. Do NOT commit. Edit if you need to add other secrets.
secret:
  appKey: "${KEY}"
  extra: {}
EOF
fi

echo "[helm] Installing/upgrading release '${RELEASE}' in ns '${NAMESPACE}' ..."
# NOTE: deliberately NO --create-namespace. Our chart's templates/namespace.yaml
# already creates it (with our labels/annotations). Using both causes a
# "namespaces already exists" conflict at apply time.
helm upgrade --install "${RELEASE}" "${ROOT}/helm/laravel-k8s" \
    --namespace "${NAMESPACE}" \
    -f "${VALUES_FILE}" \
    -f "${SECRETS_FILE}" \
    --wait --timeout 5m

echo
kubectl -n "${NAMESPACE}" get pods,svc,ingress,pvc
