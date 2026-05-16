# External Cleanup Checklist

Run after `bash scripts/99-factory-reset.sh` finishes on the Azure VM.
These steps live outside the server and have to be done by hand.

---

## 1. Cloudflare DNS — kill the public hostnames

1. Log in at <https://dash.cloudflare.com/>.
2. Pick the `chishty.me` zone.
3. Go to **DNS → Records**.
4. Delete the A records for:
   - [ ] `laravel.chishty.me`
   - [ ] `argocd.chishty.me`
   - [ ] `qtec.chishty.me` *(only if you also want the qtec dashboard down — note your CV references this domain)*

> **Heads up:** If you delete `qtec.chishty.me`, your CV's "Live Application" link will 404. Consider keeping qtec up if your CV still points at it.

---

## 2. GitHub repository (`chishty313/bdsoft`)

### a) Rotate / remove Actions secrets

1. Open <https://github.com/chishty313/bdsoft/settings/secrets/actions>.
2. Delete (or rotate by clicking **Update** and pasting a new value):
   - [ ] `DOCKERHUB_USERNAME`
   - [ ] `DOCKERHUB_TOKEN` ← **rotate on Docker Hub side first** (next section), then update here. The token leaked to chat once; rotation is recommended regardless.

### b) Optional — archive or delete the repo

- Archive (keeps it visible, read-only): Settings → bottom of page → **Archive this repository**
- Delete (gone forever, link breaks): Settings → bottom → **Delete this repository**

> Keep it if you want to keep referencing the work in interviews or future job applications. The submission and README are valuable assets — archiving is the safer choice than deleting.

---

## 3. Docker Hub — delete the published image

### a) Rotate the access token (do this first)

1. Log in at <https://hub.docker.com/>.
2. **Account Settings → Security → Personal access tokens**.
3. Find the token you used for CI. Click **Delete** (or **Edit → Regenerate**).
4. If you regenerated, paste the new value into GitHub Actions secrets (step 2a).

### b) Delete the image repo

1. Go to <https://hub.docker.com/repository/docker/src313/laravel-k8s>.
2. **Settings → Delete repository**.
3. Type the repo name to confirm.

- [ ] Token rotated / deleted
- [ ] `src313/laravel-k8s` repo deleted

---

## 4. Let's Encrypt — no action needed

The certificate cert-manager issued for `laravel.chishty.me` lives inside the
Kubernetes cluster you just destroyed. Let's Encrypt keeps no server-side state
beyond the issuance record. The cert will simply not be renewed; it expires
within 90 days of issuance with no impact on anything.

If you want to be extra tidy, you can revoke it manually — but it's not
necessary and rate-limits make this unhelpful.

---

## 5. ArgoCD — already gone

ArgoCD ran inside the cluster. When the cluster died, the ArgoCD installation,
all `Application` CRs, and the viewer account died with it. There's nothing on
"ArgoCD's side" to clean — Argo has no cloud service that holds state.

---

## 6. Azure VM itself — optional final wipe

If you want the Azure VM also gone:

1. Azure portal → **Virtual machines** → your VM.
2. **Delete** (with the disk).
3. Also delete: the VM's NIC, public IP, OS disk, NSG, VNet/subnet — or just delete the **resource group** to nuke everything in one shot.

Keep the VM running if you want to use it for future projects (it's still a
useful Ubuntu host with a public IP).

---

## Verification — quick sanity sweep after everything

From your laptop:

```bash
# Should fail to resolve OR resolve but TLS fails
curl -I https://laravel.chishty.me
curl -I https://argocd.chishty.me

# Should 404 / not found
docker pull src313/laravel-k8s:1.1.0

# GitHub Actions — go to the repo → Actions tab → trigger a workflow → should
# fail at the docker push step because the secrets are gone.
```

On the Azure VM:

```bash
multipass list 2>/dev/null        # "command not found" or "No instances"
docker ps    2>/dev/null          # "command not found" or empty list
ls ~/.kube ~/.helm ~/.config/argocd 2>/dev/null   # absent
sudo nginx -T 2>/dev/null | grep -i stream         # no output
```

If all of the above match expectations, you're clean.
