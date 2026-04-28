#!/usr/bin/env bash
#
# Container entrypoint. Runs every time a pod starts.
#  - Verifies APP_KEY is set (Laravel refuses to boot without it).
#  - Ensures the PVC-mounted storage tree exists with the right structure.
#  - Recreates `public/storage` symlink if it's missing.
#  - Rebuilds the Laravel config cache against the *runtime* environment.
#  - Hands off to whatever was passed as CMD (supervisord by default).
#
# We intentionally do NOT run `php artisan migrate` here — see README "Laravel
# runtime requirements". Migrations are executed by a Helm hook Job so they run
# exactly once per release, instead of N times (one per replica).

set -euo pipefail

APP_DIR="/var/www/html"
cd "${APP_DIR}"

log() { printf '[entrypoint] %s\n' "$*"; }

# 1) APP_KEY guard — fail loud if missing.
if [[ -z "${APP_KEY:-}" ]]; then
    log "ERROR: APP_KEY is not set. It must be supplied via Secret."
    log "Generate one with: docker run --rm php:8.3-cli php -r 'echo \"base64:\".base64_encode(random_bytes(32)).PHP_EOL;'"
    exit 1
fi

# 2) Storage tree on the PVC — create the canonical directories if a fresh PVC was just attached.
mkdir -p \
    storage/app/public \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/testing \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

# 3) public/storage symlink (idempotent).
if [[ ! -L public/storage ]]; then
    log "Creating public/storage -> storage/app/public symlink"
    php artisan storage:link || true
fi

# 4) Refresh the runtime caches now that env vars are in place.
log "Caching config / route / view"
php artisan config:cache  || true
php artisan route:cache   || true
php artisan view:cache    || true

# 5) Best-effort warmup of opcache for `index.php`.
php -r "opcache_compile_file(getcwd().'/public/index.php');" 2>/dev/null || true

log "Starting: $*"
exec "$@"
