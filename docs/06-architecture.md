# 06 — Architecture & design decisions

## End-to-end traffic path

```
                           Public Internet
                                │
                                ▼
           ┌─────────────────────────────────────┐
           │  Host VM   (Ubuntu 22.04, public IP) │
           │  ┌───────────────────────────────┐   │
           │  │ host nginx :80 / :443         │   │
           │  │   server_name laravel-test.local │
           │  │   server_name laravel.<domain>   │
           │  │   proxy_pass <WORKER_IP>:30080│   │
           │  └─────────────┬─────────────────┘   │
           │                │                     │
           │   ┌────────────┴────────────────┐    │
           │   │ KVM VMs (multipass / qemu)  │    │
           │   │                              │   │
           │   │  ┌──────────────────────┐   │   │
           │   │  │ k8s-master (CP)      │   │   │
           │   │  │ kube-apiserver:6443  │   │   │
           │   │  │ etcd, scheduler,     │   │   │
           │   │  │ controller-manager   │   │   │
           │   │  │ Calico, ingress-ngx? │   │   │
           │   │  └──────────────────────┘   │   │
           │   │                              │   │
           │   │  ┌──────────────────────┐   │   │
           │   │  │ k8s-worker           │   │   │
           │   │  │ NodePort 30080/30443 │◀──┼───┘
           │   │  │ ingress-nginx pods   │   │
           │   │  │ Laravel web pods     │   │
           │   │  │ migration Job (hook) │   │
           │   │  │ optional queue/cron  │   │
           │   │  └──────────────────────┘   │
           │   └─────────────────────────────┘
           └─────────────────────────────────────┘
```

## Resource budget (1 master + 1 worker)

| Component                     | CPU req  | Mem req | Notes                                |
|-------------------------------|----------|---------|---------------------------------------|
| Master VM (kubelet+API+etcd)  | 1.5 vCPU | 2.0 GB  | Calico operator + tigera bumps it     |
| Worker VM (kubelet+CNI)       | 0.5 vCPU | 0.5 GB  | Before any workloads                  |
| Calico DaemonSet (per node)   | 0.05 vCPU| 64 MB   |                                       |
| ingress-nginx (1 replica)     | 50 m     | 96 MB   | Lives on the worker                   |
| Laravel web (2 replicas)      | 200 m    | 384 MB  | 100 m / 192 MB each                   |
| metrics-server (optional)     | 50 m     | 64 MB   | Required for HPA                      |
| **Cluster total**             | ~3 vCPU  | ~4.5 GB | Leaves ~1 vCPU + 3.5 GB for the host  |

## Image internals

| Layer                           | Why                                                                |
|---------------------------------|---------------------------------------------------------------------|
| `composer:2.7` stage 1          | Resolve PHP deps in isolation; vendor/ doesn't ship the build tools.|
| `php:8.3-fpm-alpine` stage 2    | ~120 MB final image, official upstream, easy to patch.              |
| nginx + php-fpm + supervisord   | Single container, single failure unit; one process crash = pod restart. |
| Non-root `app` (UID 1000)       | Required for `securityContext.runAsNonRoot: true`.                  |
| nginx on :8080                  | Lets the non-root user bind without `cap_net_bind_service`.         |
| OPcache + JIT                   | Prod-grade PHP performance, validate_timestamps off.                |
| `route:cache`+`view:cache` baked | Faster boot. `config:cache` deferred to runtime (env-dependent).    |

## Why Helm hooks for migrations (not init containers)

| Approach              | Pro                          | Con                                                |
|-----------------------|------------------------------|-----------------------------------------------------|
| Init container        | Same pod lifecycle           | Runs **per replica**, races on shared DB schema.    |
| Helm hook Job         | Runs **once per release**    | Slightly more YAML. Coupled to Helm lifecycle.      |
| Manual `kubectl exec` | Operator full control        | Easy to forget. Not GitOps-friendly.                |

We picked the Helm hook Job (`pre-upgrade,post-install`).

## Why Calico (not Flannel/Cilium)

- **NetworkPolicy** out of the box, which we use to lock down the
  Laravel namespace.
- Stable on kubeadm, no kernel BPF requirements (Cilium needs ≥5.4).
- Lower memory footprint than Cilium.

## Why ingress-nginx as NodePort (not LoadBalancer / hostPort)

- No cloud LoadBalancer available on a single VM.
- HostPort would steal :80/:443 from the host's existing nginx.
- NodePort lets the host's existing nginx reverse-proxy in cleanly,
  and stays Kubernetes-idiomatic.

## Security posture summary

- Non-root container, all caps dropped, `allowPrivilegeEscalation: false`,
  `seccompProfile: RuntimeDefault`.
- ServiceAccount with `automountServiceAccountToken: false` (the app
  doesn't talk to the K8s API).
- Secrets used for `APP_KEY` (and any extras); chart `fail`s without one.
- NetworkPolicy: ingress only from ingress-nginx ns, egress restricted
  to DNS + everything else (loose by design — tighten in prod).
- Image scanned by Docker Hub's built-in scanner; CI can add Trivy.
- TLS via cert-manager + Let's Encrypt.
