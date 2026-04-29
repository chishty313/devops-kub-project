# 00 — Execution plan (day-by-day)

You have 4 days (Apr 27 → May 1). This plan paces the work so day-4 is
"polish + screenshots + push" instead of "panic". Each step lists who
runs it (you on laptop / you on the host VM / a script we wrote).

For maximum efficiency, run laptop steps and VM steps **in parallel**
windows.

---

## Legend

- 💻 **laptop** — your local workstation
- ☁️ **host** — the Azure VM (40.81.255.50), as the `azureuser` (or whatever your sudo user is)
- 🔧 **vm-X** — inside a multipass VM (cp1/cp2/cp3/w1/w2)
- ⏱ approximate wall time

---

## Day 1 — Foundation (~ 3 h)

### Step 1.1 · 💻 Set up the GitHub repo locally  *(⏱ 5 m)*

```bash
git clone https://github.com/chishty313/devops-kub-project.git
cd devops-kub-project
# Copy the project files we built (the entire content of /Users/.../bdsoft)
# into here, OR: just clone this repo if everything is already pushed.
git add .
git commit -m "feat: initial DevOps assignment scaffold"
git push -u origin main
```

### Step 1.2 · ☁️ Add DNS records at your registrar  *(⏱ 2 m + propagation)*

```
laravel.chishty.me  IN A 40.81.255.50
argocd.chishty.me   IN A 40.81.255.50
```

While DNS propagates, continue with the next steps.

### Step 1.3 · ☁️ SSH into the host and clone the repo  *(⏱ 5 m)*

```bash
ssh azureuser@40.81.255.50
git clone https://github.com/chishty313/devops-kub-project.git
cd devops-kub-project
```

### Step 1.4 · ☁️ Install Docker on the host (if not already)  *(⏱ 5 m)*

```bash
sudo apt-get update -y
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker            # reload group membership in current shell
docker --version
```

### Step 1.5 · ☁️ Generate the Laravel scaffold + customisations  *(⏱ 5 m)*

```bash
./scripts/bootstrap-laravel.sh
ls src/                  # composer.json, app/, routes/, resources/views/welcome.blade.php, ...
```

### Step 1.6 · ☁️ Build the Docker image  *(⏱ ~6 m for the first build)*

```bash
docker build -t src313/laravel-k8s:1.0.0 .
docker images | grep laravel-k8s
```

### Step 1.7 · ☁️ Smoke test the image locally  *(⏱ 2 m)*

```bash
docker run --rm -d --name laravel-smoke -p 8080:8080 \
    -e APP_ENV=local -e APP_DEBUG=true \
    -e APP_KEY="base64:$(openssl rand -base64 32)" \
    src313/laravel-k8s:1.0.0
sleep 5
curl -s http://127.0.0.1:8080/health | jq .
docker stop laravel-smoke
```

### Step 1.8 · ☁️ Push to Docker Hub  *(⏱ 3 m)*

```bash
docker login -u src313                # paste an access token (Hub > Account Settings > Security)
docker push src313/laravel-k8s:1.0.0
docker tag  src313/laravel-k8s:1.0.0 src313/laravel-k8s:latest
docker push src313/laravel-k8s:latest
```

✅ At this point: image is on Docker Hub. Day-1 done.

---

## Day 2 — Cluster (~ 3 h)

### Step 2.1 · ☁️ Provision 5 multipass VMs  *(⏱ ~10 m)*

```bash
bash scripts/05-launch-multipass-vms.sh
multipass list
cat cluster.env       # CP1_IP, CP2_IP, CP3_IP, W1_IP, W2_IP
```

### Step 2.2 · ☁️ Run prereqs on every VM in parallel  *(⏱ ~6 m)*

```bash
bash scripts/06-prereqs-on-all.sh
```

### Step 2.3 · ☁️ Pick the kube-vip VIP  *(⏱ 1 m)*

The VIP must be on the multipass bridge subnet but not assigned by DHCP.
Multipass typically uses `10.x.y.0/24` and DHCP-allocates from `.2`
upwards, so `.250` is safe.

```bash
source cluster.env
SUBNET="$(echo $CP1_IP | awk -F. '{printf "%s.%s.%s.", $1, $2, $3}')"
export CONTROL_PLANE_VIP="${SUBNET}250"
echo "VIP = $CONTROL_PLANE_VIP"

# Persist for later steps
echo "CONTROL_PLANE_VIP=$CONTROL_PLANE_VIP" >> cluster.env
```

### Step 2.4 · 🔧 cp1: kubeadm init + kube-vip + Calico  *(⏱ ~10 m)*

```bash
multipass transfer scripts/10-init-master.sh cp1:/tmp/
multipass exec cp1 -- sudo CONTROL_PLANE_VIP="$CONTROL_PLANE_VIP" \
                            ADVERTISE_ADDR="$CP1_IP" \
                            bash /tmp/10-init-master.sh
```

Watch for: "Your Kubernetes control-plane has initialized successfully!"
and a list with `cp1   Ready   control-plane`.

### Step 2.5 · 🔧 cp2 + cp3: join as control-plane  *(⏱ ~6 m)*

```bash
multipass exec cp1 -- sudo cat /root/kubeadm-join-cp.sh     > ~/kubeadm-join-cp.sh
multipass exec cp1 -- sudo cat /root/kubeadm-join-worker.sh > ~/kubeadm-join-worker.sh
chmod 755 ~/kubeadm-join-cp.sh ~/kubeadm-join-worker.sh

for n in cp2 cp3; do
    multipass transfer ~/kubeadm-join-cp.sh             "$n:/tmp/kubeadm-join-cp.sh"
    multipass transfer scripts/15-join-control-plane.sh "$n:/tmp/15.sh"
    multipass exec "$n" -- sudo CONTROL_PLANE_VIP="$CONTROL_PLANE_VIP" bash /tmp/15.sh
done

multipass exec cp1 -- kubectl get nodes -o wide
```

Expect 3 control-plane nodes, all `Ready`.

### Step 2.6 · 🔧 w1 + w2: join as worker  *(⏱ ~3 m)*

```bash
for n in w1 w2; do
    multipass transfer ~/kubeadm-join-worker.sh  "$n:/tmp/kubeadm-join-worker.sh"
    multipass transfer scripts/20-join-worker.sh "$n:/tmp/20.sh"
    multipass exec "$n" -- sudo bash /tmp/20.sh
done

multipass exec cp1 -- kubectl get nodes -o wide
```

Expect 5 nodes, all `Ready`.

### Step 2.7 · ☁️ Pull kubeconfig back to the host  *(⏱ 2 m)*

```bash
mkdir -p ~/.kube
multipass exec cp1 -- sudo cat /etc/kubernetes/admin.conf \
    | sed "s#https://${CONTROL_PLANE_VIP}:6443#https://${CP1_IP}:6443#" \
    > ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes -o wide
kubectl cluster-info
```

✅ Cluster is up. Day-2 done.

---

## Day 3 — App + Ingress + TLS + ArgoCD (~ 3 h)

### Step 3.1 · ☁️ Install ingress-nginx (NodePort 30080/30443)  *(⏱ ~5 m)*

```bash
bash scripts/30-install-ingress-nginx.sh
kubectl -n ingress-nginx get pods,svc
```

### Step 3.2 · ☁️ Install metrics-server (so HPA works)  *(⏱ ~2 m)*

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# Patch for self-signed kubeadm certs
kubectl -n kube-system patch deploy metrics-server --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
sleep 30 && kubectl top nodes
```

### Step 3.3 · ☁️ Set up the host nginx TCP forwarder  *(⏱ ~3 m)*

```bash
sudo bash scripts/25-setup-host-nginx.sh
curl -i http://127.0.0.1:8081/healthz                                    # host nginx own probe
curl -i -H "Host: laravel-test.local" http://127.0.0.1/                  # 404 from ingress (no Ingress yet)
```

### Step 3.4 · ☁️ Install cert-manager + ClusterIssuers  *(⏱ ~5 m)*

```bash
bash scripts/35-install-cert-manager.sh
kubectl get clusterissuer
```

### Step 3.5 · ☁️ Install the Laravel Helm release  *(⏱ ~3 m)*

```bash
bash scripts/40-install-helm-release.sh
kubectl -n laravel get pods,svc,ingress,pvc
kubectl -n laravel rollout status deploy/laravel-laravel-k8s
```

### Step 3.6 · ☁️ First test  *(⏱ 2 m)*

```bash
curl -i -H "Host: laravel-test.local" http://127.0.0.1/         # 200
curl -i -H "Host: laravel-test.local" http://127.0.0.1/health   # 200 JSON
```

If DNS for `laravel.chishty.me` has propagated:

```bash
curl -i http://laravel.chishty.me/
```

### Step 3.7 · ☁️ Enable TLS via cert-manager  *(⏱ ~3 m + LE wait)*

```bash
helm upgrade laravel ./helm/laravel-k8s \
    -n laravel \
    -f helm/laravel-k8s/values.yaml \
    -f secrets.local.yaml \
    --set ingress.tls.enabled=true \
    --set ingress.tls.clusterIssuer=letsencrypt-prod \
    --reuse-values

# Watch the cert come up:
kubectl -n laravel get certificate,certificaterequest,order,challenge
# After ~60-90s:
curl -I https://laravel.chishty.me/
# HTTP/2 200
```

### Step 3.8 · ☁️ Install ArgoCD + Application  *(⏱ ~5 m)*

```bash
bash scripts/45-install-argocd.sh
echo "Open https://argocd.chishty.me — admin password printed above."
```

✅ All required + most bonus features are live. Day-3 done.

---

## Day 4 — Polish, screenshots, submission (~ 2 h)

### Step 4.1 · ☁️ Capture required outputs into the repo  *(⏱ 5 m)*

```bash
mkdir -p docs/screenshots
kubectl get nodes -o wide                  | tee docs/screenshots/01-nodes.txt
kubectl get pods -A                        | tee docs/screenshots/02-pods.txt
kubectl cluster-info                       | tee docs/screenshots/03-cluster-info.txt
kubectl get ingress -A                     | tee docs/screenshots/04-ingress.txt
kubectl -n laravel describe deploy/laravel-laravel-k8s | tee docs/screenshots/05-deploy-describe.txt
kubectl -n laravel get hpa,pdb,networkpolicy | tee docs/screenshots/06-bonus.txt
helm -n laravel list                       | tee docs/screenshots/07-helm-list.txt
```

### Step 4.2 · 💻 Browser screenshots  *(⏱ 10 m)*

Open in your browser, screenshot each, save into `docs/screenshots/`:

- `https://laravel.chishty.me/` → `10-laravel-home.png`
- `https://laravel.chishty.me/health` → `11-laravel-health.png`
- `https://laravel.chishty.me/info` → `12-laravel-info.png`
- `https://argocd.chishty.me/` (logged in, showing the synced app) → `13-argocd-app.png`
- Reload the home page a few times to show the `Pod` field rotating
  → `14-laravel-pod-rotation.png`

### Step 4.3 · ☁️ Final commit + push  *(⏱ 5 m)*

```bash
cd ~/devops-kub-project
git add docs/screenshots/
git status
git commit -m "docs: add cluster outputs and live demo screenshots"
git push
```

### Step 4.4 · 💻 Sanity check the README on GitHub  *(⏱ 5 m)*

Open `https://github.com/chishty313/devops-kub-project` and verify:

- README renders cleanly with the live URLs at the top.
- Screenshots show in `docs/screenshots/`.
- All scripts are executable (`mode 755`).

### Step 4.5 · 💻 Submit  *(⏱ 5 m)*

Email the recruiter the GitHub URL:
`https://github.com/chishty313/devops-kub-project`

Mention: cluster is left running at `40.81.255.50` for live verification.

---

## Total time estimate

| Day | Activity                           | Hours |
|-----|------------------------------------|-------|
|  1  | Image build + push                 | ~3    |
|  2  | HA cluster (3 CP + 2 worker)       | ~3    |
|  3  | App + Ingress + TLS + ArgoCD       | ~3    |
|  4  | Polish + submit                    | ~2    |
|     | **Total**                          | ~11 h |

You have 4 calendar days; this fits with rest in between.

---

## What I will be doing while you execute

For each step, when you hit a snag, **paste the exact error** back to
me (and the last screen of the failing command's output). I'll diagnose
and either give you a fix command or amend a script in the repo. The
plan above already accounts for the most common gotchas
(`scripts/00-prereqs.sh` is fully idempotent, kube-vip path patching is
handled, host nginx config is templated).
