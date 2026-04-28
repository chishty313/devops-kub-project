# 02 — kubeadm cluster setup (1 master + 1 worker, nested KVM)

This doc takes you from a fresh Ubuntu 22.04 host to a working
2-node Kubernetes cluster with Calico CNI and ingress-nginx.

The single-node fallback (no nested VMs) is at the bottom.

---

## 0. Math: why 1 master + 1 worker (and not 2 + 1)

| Layout                   | Min RAM        | Notes                              |
|--------------------------|----------------|-------------------------------------|
| 1 control-plane          | ~2.5 GB        | Single-node kubeadm, taint removed.|
| 1 master + 1 worker      | ~4.5 GB        | What this doc builds.              |
| 2 master + 1 worker (HA) | ~7.5 GB        | Needs HA endpoint (kube-vip).      |

With ~8 GB free on the host (and existing nginx + Docker workloads to
keep alive), **1 master + 1 worker** is the realistic ceiling. The
assignment explicitly accepts this fallback.

---

## 1. Install multipass on the host

multipass is the easiest way to get cloud-init-driven Ubuntu VMs on top
of KVM:

```bash
sudo snap install multipass --classic
multipass version
```

Set the KVM driver explicitly:

```bash
sudo multipass set local.driver=qemu
```

If you don't have/want snap, use libvirt + virt-install with a cloud
image — same result, more typing.

## 2. Cloud-init payload (shared)

Save as `/tmp/cloud-init.yaml` on the host:

```yaml
#cloud-config
package_update: true
package_upgrade: false
packages:
  - curl
  - ca-certificates
  - gnupg
  - apt-transport-https
ssh_authorized_keys:
  - <PASTE_YOUR_PUBLIC_KEY_HERE>
runcmd:
  - hostnamectl set-hostname --static $(hostname)
  - swapoff -a
  - sed -ri '/\sswap\s/s/^/#/' /etc/fstab
```

## 3. Launch the two VMs

```bash
multipass launch 22.04 \
    --name k8s-master \
    --cpus 2 --memory 2500M --disk 12G \
    --cloud-init /tmp/cloud-init.yaml

multipass launch 22.04 \
    --name k8s-worker \
    --cpus 2 --memory 2000M --disk 10G \
    --cloud-init /tmp/cloud-init.yaml

multipass list
```

Note their IP addresses — `multipass list` shows them. Set:

```bash
export MASTER_IP=$(multipass info k8s-master | awk '/IPv4/{print $2; exit}')
export WORKER_IP=$(multipass info k8s-worker | awk '/IPv4/{print $2; exit}')
echo "MASTER_IP=$MASTER_IP   WORKER_IP=$WORKER_IP"
```

## 4. Copy the project into both VMs (or just clone it inside)

```bash
multipass transfer scripts/00-prereqs.sh   k8s-master:/tmp/
multipass transfer scripts/10-init-master.sh k8s-master:/tmp/
multipass transfer scripts/00-prereqs.sh   k8s-worker:/tmp/
multipass transfer scripts/20-join-worker.sh k8s-worker:/tmp/
```

Or, simpler, `git clone` inside each VM after pushing the repo.

## 5. Run prereqs on BOTH VMs

```bash
multipass exec k8s-master -- sudo bash /tmp/00-prereqs.sh
multipass exec k8s-worker -- sudo bash /tmp/00-prereqs.sh
```

Each takes ~3 minutes (apt update + containerd + kubeadm).

## 6. Init the control plane

```bash
multipass exec k8s-master -- \
    sudo POD_CIDR=192.168.0.0/16 ADVERTISE_ADDR=$MASTER_IP \
        bash /tmp/10-init-master.sh
```

Expected end of output: a list of nodes (just `k8s-master` for now,
status `Ready` after Calico finishes pulling).

The script wrote a join command to `/root/kubeadm-join.sh`. Pull it
out:

```bash
multipass exec k8s-master -- sudo cat /root/kubeadm-join.sh > /tmp/kubeadm-join.sh
chmod 755 /tmp/kubeadm-join.sh
multipass transfer /tmp/kubeadm-join.sh k8s-worker:/tmp/
```

## 7. Join the worker

```bash
multipass exec k8s-worker -- sudo bash /tmp/20-join-worker.sh
```

Wait ~30 seconds for Calico to settle on the worker, then:

```bash
multipass exec k8s-master -- kubectl get nodes -o wide
# NAME         STATUS   ROLES           AGE   VERSION   ...
# k8s-master   Ready    control-plane   5m    v1.30.x
# k8s-worker   Ready    <none>          1m    v1.30.x
```

## 8. Copy the kubeconfig back to the host

So you can `kubectl` from the host instead of `multipass exec ... kubectl`:

```bash
multipass exec k8s-master -- sudo cat /etc/kubernetes/admin.conf \
    | sed "s/127.0.0.1/$MASTER_IP/g" \
    > ~/.kube/config-laravel
export KUBECONFIG=~/.kube/config-laravel
kubectl get nodes -o wide
kubectl cluster-info
```

## 9. Install ingress-nginx (NodePort)

From the host (with `KUBECONFIG` set):

```bash
bash scripts/30-install-ingress-nginx.sh
```

Verify:

```bash
kubectl -n ingress-nginx get pods,svc
# svc/ingress-nginx-controller   NodePort   ...   80:30080/TCP,443:30443/TCP
```

The NodePort is reachable on **any** cluster node IP. Pick one:

```bash
curl -i http://$WORKER_IP:30080/healthz
# 404 until we deploy Laravel — that's expected. The point is: TCP works.
```

## 10. Forward host nginx traffic to the cluster

The host listens on :80. The cluster listens on $WORKER_IP:30080. Bridge
them with the vhost in `k8s/host-nginx-vhost.conf`:

```bash
sudo cp k8s/host-nginx-vhost.conf /etc/nginx/sites-available/laravel-k8s.conf
sudo sed -i "s|127.0.0.1:30080|$WORKER_IP:30080|g" \
    /etc/nginx/sites-available/laravel-k8s.conf
sudo sed -i "s/chishty\\.me/chishty.me/g" \
    /etc/nginx/sites-available/laravel-k8s.conf
sudo ln -sf /etc/nginx/sites-available/laravel-k8s.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

(See `docs/04-ingress-and-host-proxy.md` for the full reasoning.)

---

## Required outputs to capture for submission

Run these on the master and save the output to `docs/screenshots/`:

```bash
kubectl get nodes -o wide        > docs/screenshots/01-nodes.txt
kubectl get pods -A              > docs/screenshots/02-pods.txt
kubectl cluster-info             > docs/screenshots/03-cluster-info.txt
kubectl get ingress -A           > docs/screenshots/04-ingress.txt
```

Optionally take browser screenshots of:

- `http://laravel-test.local/` showing the body string.
- `http://laravel-test.local/health` showing the JSON.

Save them as PNGs alongside the text outputs.

---

## Fallback: single-node kubeadm directly on the host

If nested KVM isn't available, skip multipass and run on the host:

```bash
sudo bash scripts/00-prereqs.sh
sudo POD_CIDR=192.168.0.0/16 ADVERTISE_ADDR=$(hostname -I | awk '{print $1}') \
    bash scripts/10-init-master.sh
# Untaint so workloads can land on the only node:
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
bash scripts/30-install-ingress-nginx.sh
```

This still satisfies the assignment, and is **more honest** when the
hypervisor doesn't expose nested KVM. Mention it in the README's
"Assumptions" section if you go this route.
