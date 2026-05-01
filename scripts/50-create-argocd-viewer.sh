#!/usr/bin/env bash
#
# (Optional) Create a read-only "viewer" account in ArgoCD.
#
# This script registers a local account in argocd-cm and sets its password.
# It deliberately does NOT touch argocd-rbac-cm — ArgoCD's default
# `policy.default` is `role:readonly`, which already grants applications/get,
# projects/get, repositories/get, clusters/get on every project. That's
# exactly the read-only access we want.
#
# Why no RBAC patch? Adding a custom `policy.csv` is brittle: a single
# malformed row makes argocd-server crashloop. Relying on the built-in
# `role:readonly` is safer and still gives reviewers full read access.
#
# Run on the host (kubectl + helm available):
#     bash scripts/50-create-argocd-viewer.sh
#
# Override the password with VIEWER_PASSWORD env var. Avoid passwords with
# `!` (bash history expansion) — this script sidesteps that, but other tools
# may not.

set -euo pipefail

VIEWER_PASSWORD="${VIEWER_PASSWORD:-Reviewer2026}"

# Verify dependencies
command -v htpasswd >/dev/null 2>&1 || {
    echo "[viewer] htpasswd not found. Install with:  sudo apt-get install -y apache2-utils"
    exit 1
}

# 1) Register the local 'viewer' account in argocd-cm
echo "[viewer] Registering 'viewer' account in argocd-cm ..."
kubectl -n argocd patch configmap argocd-cm --type merge -p "$(cat <<'EOF'
{
  "data": {
    "accounts.viewer":         "login",
    "accounts.viewer.enabled": "true"
  }
}
EOF
)"

# 2) Hash the password with bcrypt and store it in argocd-secret.
#    htpasswd outputs `:$2y$10$...`; we strip the leading `:` and convert
#    the `$2y$` prefix to `$2a$` (semantically identical, broader support).
HASH="$(htpasswd -nbBC 10 "" "${VIEWER_PASSWORD}" | tr -d ':\n' | sed 's/^\$2y/$2a/')"
MTIME="$(date +%FT%T%:z)"

echo "[viewer] Setting password in argocd-secret ..."
kubectl -n argocd patch secret argocd-secret --type merge -p "$(cat <<EOF
{
  "stringData": {
    "accounts.viewer.password":      "${HASH}",
    "accounts.viewer.passwordMtime": "${MTIME}"
  }
}
EOF
)"

# 3) Restart argocd-server so it reloads the secret + cm
echo "[viewer] Restarting argocd-server ..."
kubectl -n argocd rollout restart deploy argocd-server
kubectl -n argocd rollout status  deploy argocd-server --timeout=120s

cat <<EOM

[viewer] DONE.

  Login at https://argocd.chishty.me/
    Username:  viewer
    Password:  ${VIEWER_PASSWORD}

  This account inherits ArgoCD's built-in 'role:readonly':
    list/get on applications, projects, repositories, clusters.
  It cannot sync, edit, refresh, or delete anything.

  These credentials are safe to share publicly because the account is
  read-only and the cluster will be torn down post-review.

EOM
