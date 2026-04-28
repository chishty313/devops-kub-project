#!/usr/bin/env bash
#
# Push and run scripts/00-prereqs.sh on every cluster VM in parallel.
# Sources cluster.env to know which VMs exist.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "${ROOT}/cluster.env" ]]; then
    echo "Run scripts/05-launch-multipass-vms.sh first."
    exit 1
fi
# shellcheck disable=SC1090
source "${ROOT}/cluster.env"

NODES=(cp1 cp2 cp3 w1 w2)

echo "[prereqs-all] Copying scripts/00-prereqs.sh to each VM ..."
for n in "${NODES[@]}"; do
    multipass transfer "${ROOT}/scripts/00-prereqs.sh" "${n}:/tmp/00-prereqs.sh"
done

echo "[prereqs-all] Running prereqs in parallel — tail of each log printed at the end."
pids=()
for n in "${NODES[@]}"; do
    log="/tmp/prereqs-${n}.log"
    ( multipass exec "${n}" -- sudo bash /tmp/00-prereqs.sh >"${log}" 2>&1 \
        && echo "  [ok ] ${n}" \
        || echo "  [ERR] ${n} (see ${log})"
    ) &
    pids+=($!)
done

# Wait for all
for pid in "${pids[@]}"; do wait "$pid" || true; done

echo
echo "[prereqs-all] Done. Verify with:"
echo "  for n in cp1 cp2 cp3 w1 w2; do echo \"=== \$n ===\"; multipass exec \$n -- systemctl is-active kubelet containerd; done"
