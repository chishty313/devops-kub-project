#!/usr/bin/env bash
#
# Configure the host's nginx as a pure-TCP forwarder for ports 80/443 to
# the worker nodes' ingress-nginx NodePorts. This lets cert-manager run
# Let's Encrypt HTTP-01 challenges that originate from the public
# internet and terminate inside the cluster.
#
# Run on the HOST (40.81.255.50). Requires cluster.env from
# scripts/05-launch-multipass-vms.sh.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "${ROOT}/cluster.env" ]]; then
    echo "Run scripts/05-launch-multipass-vms.sh first."
    exit 1
fi
# shellcheck disable=SC1090
source "${ROOT}/cluster.env"

echo "[host-nginx] Installing nginx (with stream module — full package) ..."
apt-get update -y
apt-get install -y nginx-full

echo "[host-nginx] Disabling default site (we own the entire :80/:443) ..."
rm -f /etc/nginx/sites-enabled/default

echo "[host-nginx] Writing /etc/nginx/nginx.conf ..."
install -m 0644 -o root -g root \
    "${ROOT}/k8s/host-nginx-stream.conf" /etc/nginx/nginx.conf

echo "[host-nginx] Filling in worker IPs (WORKER1_IP=${W1_IP}, WORKER2_IP=${W2_IP}) ..."
sed -i \
    -e "s/WORKER1_IP/${W1_IP}/g" \
    -e "s/WORKER2_IP/${W2_IP}/g" \
    /etc/nginx/nginx.conf

echo "[host-nginx] Validating ..."
nginx -t

echo "[host-nginx] (Re)starting nginx ..."
systemctl enable nginx
systemctl restart nginx

echo
echo "[host-nginx] Active listeners:"
ss -tlnp | grep -E ':80 |:443 |:8081' || true
echo
echo "[host-nginx] Smoke tests:"
echo "  curl -i http://127.0.0.1:8081/healthz   # host nginx self-check"
echo "  curl -i -H 'Host: laravel-test.local' http://127.0.0.1/health   # via the cluster"
