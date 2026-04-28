# 01 — Prerequisites

This doc lists everything that must be true on **the host VM** and on
**your laptop** before any of the other docs work.

## Host VM (the one that already serves your other sites)

### 1. Operating system

```
Ubuntu 22.04 LTS  (jammy)
```

Verify:

```bash
lsb_release -a
# Distributor ID: Ubuntu
# Description:    Ubuntu 22.04.5 LTS
# Release:        22.04
# Codename:       jammy
```

### 2. Free resources

We need to leave 4 vCPU + 4.5 GB RAM **free for the cluster** on top of
whatever else you're running. Check:

```bash
nproc                # cores
free -h              # used / free
df -h /              # need ≥ 20 GB free
```

If that's not the case, switch to single-node mode (see
`docs/02-cluster-setup.md`, "Fallback").

### 3. Already-present services we coexist with

- `nginx` (or `apache2`) on `:80` and `:443` — **left untouched**.
  We deploy ingress-nginx on NodePort `30080/30443` and have your
  existing nginx reverse-proxy to it.
- Existing `docker` containers — **left untouched**. Cluster nodes use
  containerd inside their own KVM VMs.

Verify nothing else listens on the NodePorts we'll claim:

```bash
sudo ss -tlnp | grep -E ':30080|:30443' || echo "free"
```

### 4. Nested KVM (only if running 2-node setup)

```bash
# Is virtualisation enabled?
lscpu | grep -E 'Virtualization|Hypervisor'

# Is /dev/kvm exposed?
ls -l /dev/kvm

# Will multipass be able to launch nested VMs?
sudo apt install -y cpu-checker
sudo kvm-ok
# expected: "KVM acceleration can be used"
```

If `/dev/kvm` is missing, ask the hypervisor admin to enable nested
virtualisation, OR use single-node kubeadm directly on the host.

### 5. Tooling we install along the way

| Tool       | Installed by                   | Why                                       |
|------------|---------------------------------|--------------------------------------------|
| containerd | `scripts/00-prereqs.sh`         | Container runtime for Kubernetes nodes.    |
| kubeadm    | `scripts/00-prereqs.sh`         | Cluster bootstrapper.                      |
| kubelet    | `scripts/00-prereqs.sh`         | Node agent.                                |
| kubectl    | `scripts/00-prereqs.sh`         | CLI.                                       |
| Calico     | `scripts/10-init-master.sh`     | CNI (NetworkPolicy capable).               |
| Helm 3     | `scripts/30-install-ingress-nginx.sh` (auto-installs if missing) | Chart manager. |
| ingress-nginx | `scripts/30-install-ingress-nginx.sh` | HTTP ingress controller.                   |
| metrics-server | manual `kubectl apply`        | Powers HPA. Optional.                      |
| cert-manager  | manual `helm install`         | Bonus: TLS via Let's Encrypt.             |

### 6. Outbound network access from cluster nodes

The cluster VMs need outbound HTTPS to:

- `pkgs.k8s.io`           (apt repo for kubeadm/kubelet/kubectl)
- `registry.k8s.io`       (control-plane images)
- `docker.io`, `quay.io`, `ghcr.io` (CNI, ingress-nginx, your Laravel image)
- `acme-v02.api.letsencrypt.org` (cert-manager, only if TLS is enabled)

A NAT-on-host setup (the multipass default) handles this automatically.

## Laptop (your workstation)

| Tool        | Why                                 |
|-------------|--------------------------------------|
| `git`       | Clone / commit / push.               |
| `ssh`       | Reach the VM.                        |
| `kubectl`   | Optional, for remote `kubectl` use.  |
| `curl`      | Hit the deployed app.                |
| `docker`    | Optional, for local image testing.   |

If you want to drive `kubectl` from your laptop instead of from the
master VM, copy `~/.kube/config` from the master and edit `server:` to
the master VM's IP:

```bash
scp master:~/.kube/config ~/.kube/config-laravel
KUBECONFIG=~/.kube/config-laravel kubectl get nodes
```
