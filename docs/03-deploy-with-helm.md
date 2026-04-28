# 03 — Deploy with Helm

Once the cluster is up (docs/02), this is the everyday flow.

---

## 1. Install Helm 3 (if missing)

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## 2. First install (no APP_KEY yet)

```bash
# Generate APP_KEY once:
APP_KEY="base64:$(openssl rand -base64 32)"

# Install:
helm upgrade --install laravel ./helm/laravel-k8s \
    --namespace laravel --create-namespace \
    -f helm/laravel-k8s/values.yaml \
    --set image.repository=src313/laravel-k8s \
    --set image.tag=1.0.0 \
    --set secret.appKey="$APP_KEY" \
    --wait --timeout 5m
```

Or use the wrapper that persists APP_KEY into a gitignored
`secrets.local.yaml`:

```bash
bash scripts/40-install-helm-release.sh
```

## 3. Verify

```bash
kubectl -n laravel get pods,svc,ingress,pvc
kubectl -n laravel rollout status deploy/laravel-laravel-k8s
kubectl -n laravel logs -l app.kubernetes.io/component=web --tail=50
```

The migration Job runs as a Helm hook. Check it:

```bash
kubectl -n laravel get jobs
kubectl -n laravel logs -l app.kubernetes.io/component=migration
```

## 4. Smoke test the rendered app via the cluster Service

(Bypasses Ingress, useful for isolating layers.)

```bash
kubectl -n laravel run curl --rm -i --tty --image=curlimages/curl --restart=Never -- \
    curl -i http://laravel-laravel-k8s.laravel.svc.cluster.local/
```

## 5. Smoke test via Ingress

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane!="")].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
NODE_IP=${NODE_IP:-$(kubectl get nodes -o wide | awk 'NR==2{print $6}')}

curl -i -H "Host: laravel-test.local" http://$NODE_IP:30080/
curl -i -H "Host: laravel-test.local" http://$NODE_IP:30080/health
```

## 6. Upgrade to a new image tag

```bash
# Build & push:
docker build -t src313/laravel-k8s:1.0.1 .
docker push  src313/laravel-k8s:1.0.1

# Upgrade:
helm upgrade laravel ./helm/laravel-k8s \
    -n laravel \
    -f helm/laravel-k8s/values.yaml \
    -f secrets.local.yaml \
    --set image.tag=1.0.1 \
    --wait
```

A pre-upgrade Helm hook re-runs migrations before the new pods roll out.

## 7. Roll back

```bash
helm history laravel -n laravel
helm rollback laravel <REVISION> -n laravel
```

## 8. Uninstall

```bash
helm uninstall laravel -n laravel

# PVC is preserved (helm.sh/resource-policy: keep). Delete it explicitly:
kubectl -n laravel delete pvc -l app.kubernetes.io/instance=laravel
kubectl delete ns laravel
```

## 9. Useful overrides

| Goal                                  | Flag                                                                 |
|---------------------------------------|----------------------------------------------------------------------|
| Skip migrations                       | `--set migration.enabled=false`                                      |
| Switch to MySQL                       | `--set config.DB_CONNECTION=mysql --set config.DB_HOST=...`          |
| Add a DB password                     | `--set-string secret.extra.DB_PASSWORD=changeme`                     |
| Bigger PVC                            | `--set persistence.size=5Gi --set persistence.storageClassName=longhorn` |
| Disable HPA, force replica count      | `--set hpa.enabled=false --set replicaCount=3`                       |
| Enable queue worker                   | `--set queue.enabled=true --set config.QUEUE_CONNECTION=redis`       |
| Enable scheduler                      | `--set scheduler.enabled=true`                                       |
| Use private registry                  | `--set imagePullSecret.create=true --set imagePullSecret.username=... --set imagePullSecret.password=...` |
| Enable TLS                            | `--set ingress.tls.enabled=true --set ingress.tls.clusterIssuer=letsencrypt-prod` |

## 10. Render without applying (debug templating)

```bash
helm template laravel ./helm/laravel-k8s \
    -f helm/laravel-k8s/values.yaml \
    --set secret.appKey="base64:dGVzdGluZw==" \
    > /tmp/rendered.yaml
less /tmp/rendered.yaml
```
