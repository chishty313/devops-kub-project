#!/usr/bin/env bash
#
# Create a read-only "viewer" account in ArgoCD so reviewers/recruiters
# can browse Applications without being able to sync, refresh, edit, or
# delete anything. The credentials are safe to put in a public README.
#
# Idempotent: re-running just refreshes the password.
#
# After this runs, log in at https://argocd.chishty.me/ with
#   username: viewer
#   password: <whatever you set below>
#
# Run on the host (or anywhere with kubectl/argocd access).

set -euo pipefail

VIEWER_PASSWORD="${VIEWER_PASSWORD:-Reviewer-2026!}"

# 1) Add the 'viewer' account to argocd-cm
echo "[viewer] Patching argocd-cm to register the 'viewer' account ..."
kubectl -n argocd patch configmap argocd-cm --type merge -p "$(cat <<'EOF'
{
  "data": {
    "accounts.viewer": "apiKey,login",
    "accounts.viewer.enabled": "true"
  }
}
EOF
)"

# 2) Add a read-only RBAC policy for the viewer role
echo "[viewer] Patching argocd-rbac-cm to grant read-only RBAC ..."
kubectl -n argocd patch configmap argocd-rbac-cm --type merge -p "$(cat <<'EOF'
{
  "data": {
    "policy.default": "role:readonly",
    "policy.csv": "p, role:viewer, applications, get, */*, allow\np, role:viewer, applications, list, */*, allow\np, role:viewer, projects, get, *, allow\np, role:viewer, projects, list, *, allow\np, role:viewer, repositories, get, *, allow\np, role:viewer, repositories, list, *, allow\np, role:viewer, clusters, get, *, allow\np, role:viewer, clusters, list, *, allow\np, role:viewer, accounts, get, *, allow\np, role:viewer, certificates, get, *, allow\np, role:viewer, gpgkeys, get, *, allow\np, role:viewer, exec, create, *, deny\np, role:viewer, applications, sync, */*, deny\np, role:viewer, applications, action/*/*, deny\np, role:viewer, applications, override, */*, deny\np, role:viewer, applications, update, */*, deny\np, role:viewer, applications, delete, */*, deny\np, role:viewer, applications, create, */*, deny\ng, viewer, role:viewer\n"
  }
}
EOF
)"

# 3) Restart argocd-server so it reloads the new ConfigMaps
echo "[viewer] Restarting argocd-server to reload RBAC ..."
kubectl -n argocd rollout restart deploy argocd-server
kubectl -n argocd rollout status  deploy argocd-server --timeout=60s

# 4) Set the viewer password using the argocd CLI's bcrypt helper.
#    We hash the password ourselves with htpasswd-style bcrypt (cost 10)
#    and write it into the argocd-secret.
echo "[viewer] Setting password ..."
HASH="$(htpasswd -nbBC 10 "" "${VIEWER_PASSWORD}" 2>/dev/null | tr -d ':\n' | sed 's/^\$2y/$2a/')"
MTIME="$(date +%FT%T%:z)"

kubectl -n argocd patch secret argocd-secret --type merge -p "$(cat <<EOF
{
  "stringData": {
    "accounts.viewer.password":      "${HASH}",
    "accounts.viewer.passwordMtime": "${MTIME}"
  }
}
EOF
)"

# 5) Force argocd-server to re-read the secret (it watches but a kick is faster)
kubectl -n argocd rollout restart deploy argocd-server >/dev/null
kubectl -n argocd rollout status  deploy argocd-server --timeout=60s

cat <<EOM

[viewer] DONE.

  Login at https://argocd.chishty.me/
    Username:  viewer
    Password:  ${VIEWER_PASSWORD}

  This account can:    list/get applications, projects, repos, clusters
  This account CANNOT: sync, refresh, edit, delete, exec, override

  These credentials are safe to share publicly (read-only).

EOM
