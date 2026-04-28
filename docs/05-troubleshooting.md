# 05 — Troubleshooting

A grab-bag of "this happened to me, here's the fix" notes. Organised
roughly by layer.

---

## kubeadm / cluster level

### `kubeadm init` hangs at "waiting for the kubelet to boot the control plane …"

**Cause**: containerd is using the wrong cgroup driver, or swap is on.

```bash
# Confirm
sudo grep SystemdCgroup /etc/containerd/config.toml
# Should be: SystemdCgroup = true
sudo swapon --show
# Should be empty.

# Fix
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo swapoff -a && sudo sed -ri '/\sswap\s/s/^/#/' /etc/fstab
sudo kubeadm reset -f && sudo bash scripts/10-init-master.sh
```

### Worker stuck `NotReady` forever

```bash
# On the worker:
sudo journalctl -u kubelet -n 100 --no-pager
```

Common causes:

- CNI not installed yet on the master. Apply Calico, wait 60 s, retry.
- Pod-CIDR mismatch (master initialised with `192.168.0.0/16` but
  Calico installed with `10.244.0.0/16`). Re-init or fix Installation.
- `br_netfilter` / `overlay` modules not loaded. Re-run
  `scripts/00-prereqs.sh`.

### `kubectl get nodes` works, but pods on the worker can't reach pods on the master (or vice-versa)

Calico VXLAN mode needs UDP/4789 between nodes. With multipass on the
default bridge, UDP traffic flows freely; if you're using a private
libvirt network with a firewall, allow it:

```bash
sudo ufw allow from <other_node_ip> to any port 4789 proto udp
```

---

## Image / registry

### `ImagePullBackOff` on the Laravel pod

```bash
kubectl -n laravel describe pod -l app.kubernetes.io/component=web | tail -20
```

- "manifest unknown" → tag doesn't exist in the registry. Did you push?
- "denied: requested access to the resource is denied" → private repo,
  but no imagePullSecret. Enable `imagePullSecret.create=true` in values.
- "no such host docker.io" → DNS broken inside the cluster. Check
  CoreDNS pods (`kubectl -n kube-system get pods -l k8s-app=kube-dns`).

### Image is too large / build takes forever

- Make sure `.dockerignore` is excluding `node_modules/`, `vendor/`,
  `.git/`, etc.
- Use BuildKit cache:
  `DOCKER_BUILDKIT=1 docker build --cache-from <user>/laravel-k8s:latest -t ...`

---

## Laravel boot

### `No application encryption key has been specified.`

`secret.appKey` is empty. Generate and pass:

```bash
KEY="base64:$(openssl rand -base64 32)"
helm upgrade laravel ./helm/laravel-k8s -n laravel --reuse-values --set secret.appKey="$KEY"
```

### `SQLSTATE[HY000] [2002] Connection refused` (or similar DB error)

You're using `DB_CONNECTION=mysql` (or pgsql) but no DB host is reachable
from the cluster. Either:

- Set `config.DB_CONNECTION=sqlite` (no DB needed for the assignment),
- Or set `config.DB_HOST` / `config.DB_USERNAME` / `secret.extra.DB_PASSWORD`
  and make sure the cluster can reach the DB.

### Health check returns 500 instead of 200

```bash
kubectl -n laravel logs -l app.kubernetes.io/component=web --tail=100
```

Most often: `APP_KEY` got cached into `bootstrap/cache/config.php` with
a stale value. Delete the cache and let entrypoint rebuild it:

```bash
kubectl -n laravel exec -it deploy/laravel-laravel-k8s -- php artisan config:clear
kubectl -n laravel rollout restart deploy/laravel-laravel-k8s
```

### Storage permission denied

The PVC was provisioned with a UID/GID that doesn't match the container's
non-root user. The chart sets `fsGroup: 1000` on the pod, which fixes
this on most CSI drivers. If your storage class doesn't honor `fsGroup`,
add an init container that `chown`s the mount.

---

## Ingress

### `kubectl get ingress -A` shows no ADDRESS

Expected for NodePort topology (no LoadBalancer to assign one).
Reach the app via `<NODE_IP>:30080`.

### 404 from ingress-nginx

The Host header didn't match the Ingress rule. Either:

```bash
curl -i -H "Host: laravel-test.local" http://<NODE_IP>:30080/
```

…or add `laravel-test.local` to your `/etc/hosts` and let the host
nginx forward.

### 502 Bad Gateway from the host nginx

The cluster NodePort isn't reachable from the host. Check from the host:

```bash
curl -v http://<WORKER_VM_IP>:30080/
```

- Connection refused → NodePort range not exposed (default is
  30000-32767, that's fine). Check `kubectl -n ingress-nginx get svc`.
- Timeout → firewall on the worker VM. Multipass VMs typically have
  no ufw, but if you set one up, allow 30000-32767/tcp.

---

## Helm

### `Error: failed pre-upgrade: ... migration ... ImagePullBackOff`

Migration Job ran before the new image was pulled. Either pre-pull on
the worker, or set `migration.enabled=false` for the first deploy
and run migrations manually after pods are healthy.

### `Error: rendered manifests contain a resource that already exists`

Some object was created outside Helm. List the namespace's resources:

```bash
kubectl -n laravel get all,ingress,pvc,secret,configmap
```

Either delete the stray object, or `helm upgrade --force` to take it over.

### Chart `template` succeeds but `install` fails on the Secret

Most often: the `fail` guard in `secret.yaml` triggered because
`secret.appKey` is empty. Pass it via `--set` or `-f secrets.local.yaml`.

---

## Diagnostics — quick "where am I broken" tour

```bash
# 1. Cluster healthy?
kubectl get nodes -o wide
kubectl -n kube-system get pods

# 2. Ingress controller healthy?
kubectl -n ingress-nginx get pods,svc

# 3. Laravel pods healthy?
kubectl -n laravel get pods,svc,ingress,pvc

# 4. Logs
kubectl -n laravel logs -l app.kubernetes.io/component=web --tail=200

# 5. Inside the pod
kubectl -n laravel exec -it deploy/laravel-laravel-k8s -- sh
# > curl -i http://127.0.0.1:8080/health
# > php artisan --version
# > ls -la storage/

# 6. From a debug pod, talk to the Service
kubectl -n laravel run debug --rm -it --image=curlimages/curl --restart=Never -- \
    curl -i http://laravel-laravel-k8s/health
```
