# 04 — Ingress & host nginx reverse proxy

The host VM is already serving other sites on `:80`/`:443`. We can't
let ingress-nginx grab those ports. The clean pattern is:

```
client ─▶ host nginx (:80/:443) ─▶ NodePort (k8s-worker:30080) ─▶ ingress-nginx ─▶ Service ─▶ Pod
```

This doc shows how to wire it.

---

## 1. Ingress object (rendered by Helm)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: laravel-laravel-k8s
  namespace: laravel
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "32m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  ingressClassName: nginx
  rules:
    - host: laravel-test.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: laravel-laravel-k8s, port: { number: 80 } }
```

Verify:

```bash
kubectl get ingress -A
# NAMESPACE   NAME                  CLASS   HOSTS                ADDRESS   PORTS
# laravel     laravel-laravel-k8s   nginx   laravel-test.local             80
```

The empty `ADDRESS` is normal in this NodePort topology — there's no
LoadBalancer to assign one. Reach the ingress via the NodePort:

```bash
curl -i -H "Host: laravel-test.local" http://<NODE_IP>:30080/health
```

## 2. Host nginx vhost

Already provided as `k8s/host-nginx-vhost.conf`. Install it:

```bash
sudo cp k8s/host-nginx-vhost.conf /etc/nginx/sites-available/laravel-k8s.conf
sudo sed -i "s|127.0.0.1:30080|<WORKER_VM_IP>:30080|g" \
    /etc/nginx/sites-available/laravel-k8s.conf
sudo sed -i "s/chishty.me/your.real.domain/g" \
    /etc/nginx/sites-available/laravel-k8s.conf
sudo ln -sf /etc/nginx/sites-available/laravel-k8s.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

Now the traffic path is:

| Step | Where it happens                       | Listening on                |
|------|----------------------------------------|------------------------------|
| 1    | Browser DNS / `/etc/hosts`             | -> VM public IP              |
| 2    | Host nginx (laravel-test.local vhost)  | :80                          |
| 3    | proxy_pass                             | -> WORKER_VM_IP:30080        |
| 4    | ingress-nginx controller pod           | :80 inside cluster           |
| 5    | Service (ClusterIP)                    | :80                          |
| 6    | Pod (php-fpm via nginx in container)   | :8080                        |

## 3. /etc/hosts on the reviewer's machine

```bash
echo "40.81.255.50  laravel-test.local" | sudo tee -a /etc/hosts
curl -i http://laravel-test.local/health
# HTTP/1.1 200 OK
```

Or, no `/etc/hosts` edit needed:

```bash
curl -i --resolve laravel-test.local:80:40.81.255.50 http://laravel-test.local/health
```

## 4. Real domain + TLS via cert-manager

### 4.1 DNS

Add an A record:

```
laravel.chishty.me.   300   IN A   40.81.255.50
```

Wait for it to propagate (`dig +short laravel.chishty.me`).

### 4.2 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set installCRDs=true \
    --wait
```

### 4.3 Apply ClusterIssuers

```bash
# Edit the email field first if needed
kubectl apply -f k8s/cert-manager-issuer.yaml
kubectl get clusterissuer
```

### 4.4 Enable TLS on the chart

```bash
helm upgrade laravel ./helm/laravel-k8s \
    -n laravel \
    -f helm/laravel-k8s/values.yaml \
    -f secrets.local.yaml \
    --set ingress.host=laravel.chishty.me \
    --set ingress.tls.enabled=true \
    --set ingress.tls.clusterIssuer=letsencrypt-prod
```

cert-manager will:

1. See the Ingress annotation `cert-manager.io/cluster-issuer`.
2. Spawn an **Order** + **Challenge** for the host.
3. Create a temporary Ingress for `/.well-known/acme-challenge/...`.
4. Once Let's Encrypt validates, save the cert to
   `secret/laravel-tls` and the main Ingress starts serving HTTPS.

Watch progress:

```bash
kubectl -n laravel get certificate,certificaterequest,order,challenge
kubectl -n laravel describe certificate laravel-tls
```

### 4.5 Tell the host nginx to stop terminating TLS

If you've been using certbot/letsencrypt directly on the host nginx,
either:

- Keep host nginx terminating TLS and forward decrypted HTTP to
  the cluster on `:30080` (current setup) — **simpler**, but
  cert-manager isn't doing the work.
- OR switch host nginx to **TCP passthrough** (`stream {}` block)
  for `:443` so the encrypted traffic reaches ingress-nginx and
  cert-manager terminates TLS — **purer**, requires nginx with
  the stream module and SNI routing.

For the assignment, the first approach is fine and is what the
host vhost file uses. We document the second as a "production
improvement" in the README.

## 5. Common gotchas

- **502 from `laravel-test.local`** — host nginx vhost wasn't reloaded,
  or the cluster ingress controller isn't on `30080`. Test directly:
  `curl http://<NODE_IP>:30080/healthz`.
- **404 from ingress-nginx** — Host header doesn't match the Ingress
  rule. Use `curl -H "Host: laravel-test.local" ...`.
- **`x509: certificate is valid for ...`** — Let's Encrypt cert hasn't
  finished yet (or you're in staging). Check Certificate status.
- **`http: server gave HTTP response to HTTPS client`** — you're
  hitting `:30080` with HTTPS. Use `:30443` for HTTPS, or HTTP for `:30080`.
