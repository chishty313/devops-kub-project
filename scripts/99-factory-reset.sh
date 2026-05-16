#!/usr/bin/env bash
#
# 99-factory-reset.sh — wipe the bdsoft cluster + host config back to a vanilla
# Ubuntu Azure VM. Idempotent: re-runs cleanly if some pieces are already gone.
#
# Run ON the Azure VM (the one that hosts the Multipass cluster + host nginx).
# Run as a user with sudo. The script will NEVER touch SSH server config, so
# you cannot get locked out by running it over SSH.
#
# Usage:
#   bash scripts/99-factory-reset.sh           # interactive — confirms before each phase
#   bash scripts/99-factory-reset.sh --yes     # non-interactive
#
# What it does, in order:
#   Phase 0  — sanity checks (hostname, sudo, network)
#   Phase 1  — remove local kubectl / helm / argocd configs
#   Phase 2  — delete all Multipass VMs (cp1, cp2, cp3, worker-1, worker-2)
#   Phase 3  — uninstall Multipass (snap)
#   Phase 4  — uninstall KVM / libvirt (host-only)
#   Phase 5  — revert host nginx to default (or remove the package)
#   Phase 6  — Docker: prune images/containers/volumes
#   Phase 7  — clean /etc/hosts entries we added
#   Phase 8  — remove cron jobs / systemd timers we added
#   Phase 9  — remove our directories (/opt/k8s-bootstrap, ~/.kube, etc.)
#   Phase 10 — final summary + manual external-cleanup checklist
#
# What it does NOT touch:
#   - openssh-server (so you keep your SSH session)
#   - ufw rules for port 22 (same reason)
#   - your home directory's dotfiles outside ~/.kube ~/.helm ~/.config/argocd
#   - apt-installed packages other than the ones we installed (nginx, multipass,
#     docker.io, kvm) — and even those only on explicit confirmation
#   - the actual /etc/hosts line for localhost / ipv6 / Ubuntu defaults

set -euo pipefail

YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=1 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# ----- helpers -----------------------------------------------------------

C_INFO=$'\033[1;36m'
C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'
C_OK=$'\033[1;32m'
C_OFF=$'\033[0m'

info()   { echo -e "${C_INFO}[reset]${C_OFF} $*"; }
warn()   { echo -e "${C_WARN}[reset]${C_OFF} $*"; }
err()    { echo -e "${C_ERR}[reset]${C_OFF} $*"; }
ok()     { echo -e "${C_OK}[reset]${C_OFF} $*"; }
phase()  { echo; echo -e "${C_INFO}===== $* =====${C_OFF}"; }

confirm() {
    local prompt="$1"
    if [ "$YES" -eq 1 ]; then
        info "$prompt — auto-yes (--yes)"
        return 0
    fi
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

run() {
    # Run a command but never fail the script if it errors (cleanup is tolerant).
    info "\$ $*"
    "$@" || warn "  (non-fatal: command returned $?)"
}

# ----- Phase 0 — sanity checks ------------------------------------------

phase "Phase 0 — sanity checks"

info "Host:     $(hostname)"
info "User:     $(whoami)"
info "Working:  $(pwd)"
info "Uptime:   $(uptime -p 2>/dev/null || true)"

if [ "$(id -u)" -eq 0 ]; then
    warn "Running as root. You can continue but sudo is unnecessary."
fi

if ! sudo -n true 2>/dev/null; then
    info "sudo will prompt for your password during phases that need it."
fi

cat <<EOM

This script will:
  • Delete Multipass VMs: cp1 cp2 cp3 worker-1 worker-2
  • Uninstall Multipass, KVM/libvirt (if present)
  • Revert /etc/nginx/nginx.conf to default
  • Prune Docker images / containers / volumes
  • Remove /etc/hosts entries for laravel-test.local
  • Remove ~/.kube ~/.helm ~/.config/argocd

It will NOT touch:
  • openssh-server (you stay logged in)
  • UFW rule for port 22
  • Anything outside the items listed above

EOM

if ! confirm "Proceed with the full factory reset?"; then
    err "Aborted by user."
    exit 1
fi

# ----- Phase 1 — local kubectl/helm/argocd configs ----------------------

phase "Phase 1 — local CLI configs"

run rm -rf "$HOME/.kube"
run rm -rf "$HOME/.helm"
run rm -rf "$HOME/.config/helm"
run rm -rf "$HOME/.config/argocd"
run rm -rf "$HOME/.cache/helm"
ok "Local kube/helm/argocd configs removed."

# ----- Phase 2 — delete Multipass VMs -----------------------------------

phase "Phase 2 — delete Multipass VMs"

if command -v multipass >/dev/null 2>&1; then
    info "Current Multipass instances:"
    multipass list || true

    for vm in cp1 cp2 cp3 worker-1 worker-2; do
        if multipass list 2>/dev/null | awk '{print $1}' | grep -qx "$vm"; then
            run multipass stop  "$vm"
            run multipass delete "$vm" --purge
        else
            info "  $vm: not present, skipping"
        fi
    done

    # Catch-all: purge any remaining stopped/deleted instances
    run multipass purge
    ok "Multipass VMs deleted."
else
    info "multipass not installed — nothing to delete."
fi

# ----- Phase 3 — uninstall Multipass ------------------------------------

phase "Phase 3 — uninstall Multipass"

if command -v multipass >/dev/null 2>&1; then
    if confirm "Uninstall the multipass snap?"; then
        run sudo snap remove --purge multipass
        ok "Multipass uninstalled."
    else
        info "Keeping multipass installed."
    fi
else
    info "multipass not installed — skipping."
fi

# ----- Phase 4 — uninstall KVM / libvirt --------------------------------

phase "Phase 4 — uninstall KVM / libvirt (host-only)"

if dpkg -l 2>/dev/null | grep -qE '^ii\s+(qemu-kvm|libvirt-daemon-system|virt-manager)\b'; then
    if confirm "Uninstall qemu-kvm + libvirt + virt-manager?"; then
        run sudo systemctl stop libvirtd 2>/dev/null
        run sudo systemctl disable libvirtd 2>/dev/null
        run sudo apt-get purge -y qemu-kvm libvirt-daemon-system libvirt-clients virt-manager bridge-utils
        run sudo apt-get autoremove -y
        # Remove libvirt state if any
        run sudo rm -rf /var/lib/libvirt /etc/libvirt
        ok "KVM / libvirt removed."
    else
        info "Keeping KVM / libvirt installed."
    fi
else
    info "qemu-kvm / libvirt not installed — skipping."
fi

# ----- Phase 5 — host nginx ---------------------------------------------

phase "Phase 5 — host nginx (revert or remove)"

if command -v nginx >/dev/null 2>&1; then
    # Back up our custom nginx.conf
    if [ -f /etc/nginx/nginx.conf ]; then
        ts="$(date +%Y%m%d-%H%M%S)"
        run sudo cp /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bdsoft-backup.${ts}"
        info "Backed up /etc/nginx/nginx.conf → /etc/nginx/nginx.conf.bdsoft-backup.${ts}"
    fi

    echo
    echo "Choose what to do with nginx:"
    echo "  1) Revert /etc/nginx/nginx.conf to the package default (recommended)"
    echo "  2) Uninstall nginx entirely"
    echo "  3) Leave nginx alone (keep the bdsoft stream config)"
    read -r -p "Choice [1/2/3]: " nginx_choice

    case "${nginx_choice:-1}" in
        1)
            # Re-install the default config from the nginx package
            run sudo apt-get install --reinstall -y nginx-common
            # Default Ubuntu nginx.conf lives in /usr/share/doc or is shipped via the deb
            if [ -f /usr/share/nginx/nginx.conf ]; then
                run sudo cp /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf
            fi
            # Clean any extra sites we added
            run sudo rm -f /etc/nginx/sites-enabled/laravel-test.local
            run sudo rm -f /etc/nginx/sites-enabled/laravel.chishty.me
            run sudo rm -f /etc/nginx/sites-enabled/argocd.chishty.me
            run sudo rm -f /etc/nginx/conf.d/stream*.conf
            # Test config; only restart if it parses
            if sudo nginx -t 2>/dev/null; then
                run sudo systemctl restart nginx
                ok "nginx reverted to default and restarted."
            else
                warn "nginx config does NOT parse — leaving service stopped. Inspect /etc/nginx."
                run sudo systemctl stop nginx
            fi
            ;;
        2)
            run sudo systemctl stop nginx
            run sudo systemctl disable nginx
            run sudo apt-get purge -y 'nginx*'
            run sudo apt-get autoremove -y
            run sudo rm -rf /etc/nginx /var/log/nginx /var/www/html
            ok "nginx fully removed."
            ;;
        3)
            info "Leaving nginx config in place."
            ;;
        *)
            warn "Unrecognised choice — leaving nginx alone."
            ;;
    esac
else
    info "nginx not installed — skipping."
fi

# ----- Phase 6 — Docker --------------------------------------------------

phase "Phase 6 — Docker cleanup"

if command -v docker >/dev/null 2>&1; then
    info "Stopping all running containers..."
    run sudo docker ps -aq | xargs -r sudo docker stop
    info "Removing all containers, images, volumes, networks..."
    run sudo docker system prune -af --volumes
    ok "Docker pruned."

    if confirm "Uninstall Docker entirely?"; then
        run sudo systemctl stop docker
        run sudo systemctl disable docker
        run sudo apt-get purge -y docker.io docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        run sudo apt-get autoremove -y
        run sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
        ok "Docker uninstalled."
    else
        info "Keeping Docker installed (cleaned only)."
    fi
else
    info "Docker not installed — skipping."
fi

# ----- Phase 7 — /etc/hosts entries -------------------------------------

phase "Phase 7 — /etc/hosts cleanup"

if [ -w /etc/hosts ] || sudo -n test -w /etc/hosts 2>/dev/null; then
    ts="$(date +%Y%m%d-%H%M%S)"
    run sudo cp /etc/hosts "/etc/hosts.bdsoft-backup.${ts}"
    # Remove any line that mentions our hostnames
    run sudo sed -i.bak \
        -e '/laravel-test\.local/d' \
        -e '/laravel\.chishty\.me/d' \
        -e '/argocd\.chishty\.me/d' \
        -e '/qtec\.chishty\.me/d' \
        /etc/hosts
    ok "/etc/hosts cleaned. Backup at /etc/hosts.bdsoft-backup.${ts}"
fi

# ----- Phase 8 — cron / systemd timers ----------------------------------

phase "Phase 8 — cron jobs / systemd timers"

# User crontab
if crontab -l 2>/dev/null | grep -q -E 'bdsoft|laravel|argocd|multipass'; then
    info "Cleaning user crontab entries that mention bdsoft/laravel/argocd/multipass..."
    crontab -l 2>/dev/null \
        | grep -v -E 'bdsoft|laravel|argocd|multipass' \
        | crontab - || true
fi

# Root crontab (some of our scripts may have installed here)
if sudo crontab -l 2>/dev/null | grep -q -E 'bdsoft|laravel|argocd|multipass'; then
    info "Cleaning root crontab entries..."
    sudo crontab -l 2>/dev/null \
        | grep -v -E 'bdsoft|laravel|argocd|multipass' \
        | sudo crontab - || true
fi

# Drop-ins under /etc/cron.d
for f in /etc/cron.d/bdsoft* /etc/cron.d/laravel* /etc/cron.d/argocd*; do
    [ -e "$f" ] && run sudo rm -f "$f"
done

ok "Cron entries cleaned."

# ----- Phase 9 — our directories ----------------------------------------

phase "Phase 9 — remove bdsoft artifacts on disk"

paths=(
    "$HOME/.cache/k8s-bootstrap"
    "$HOME/bdsoft"
    "/opt/bdsoft"
    "/opt/k8s-bootstrap"
    "/srv/bdsoft"
    "/var/log/bdsoft"
)
for p in "${paths[@]}"; do
    if [ -e "$p" ]; then
        run sudo rm -rf "$p"
    fi
done
ok "On-disk bdsoft artifacts removed."

# ----- Final summary -----------------------------------------------------

phase "Done — final summary"

cat <<EOM
${C_OK}Server-side cleanup complete.${C_OFF}

What still lives outside this VM (manual steps):

  1) Cloudflare DNS — remove A records you created
     • laravel.chishty.me
     • argocd.chishty.me
     • qtec.chishty.me (if you also want qtec down)

  2) GitHub repository (chishty313/bdsoft)
     • Settings → Secrets and variables → Actions
       Delete or rotate DOCKERHUB_USERNAME, DOCKERHUB_TOKEN
       (You leaked the token to chat earlier — rotate it on Docker Hub too.)
     • Optional: archive or delete the repo if you don't need it any more.

  3) Docker Hub (hub.docker.com)
     • Repositories → src313/laravel-k8s → Settings → Delete repository

  4) Let's Encrypt — no action needed.
     The cert was issued to your domain; it will simply expire in <90 days.
     No backend state lives outside the cluster.

  5) ArgoCD application — already gone, because it lived inside the K8s
     cluster that you just nuked. Nothing left on Argo's side.

What's left on this VM (intentionally):
  • openssh-server  (so you can still log in)
  • UFW rule for port 22
  • Default apt-installed Ubuntu packages

To verify clean state:
  multipass list 2>/dev/null    # should be: command not found  OR  "No instances"
  docker ps    2>/dev/null      # should be: command not found  OR  empty
  curl -I http://localhost      # should fail or return default Ubuntu nginx page
  ls ~/.kube ~/.helm ~/.config/argocd 2>/dev/null   # should all be absent

If you want to reboot the host to flush any lingering state:
  sudo reboot

EOM
