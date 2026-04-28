#!/usr/bin/env bash
#
# bootstrap-laravel.sh
# --------------------
# One-shot script that creates a fresh Laravel 11 project under ./src
# and overlays our customisations (routes/web.php, .env.example).
#
# Run this ONCE, on any machine that has docker installed, from the
# project root:
#
#     ./scripts/bootstrap-laravel.sh
#
# The script uses the official `composer:2.7` image so you don't need
# PHP/Composer installed locally. After it finishes, commit the resulting
# `src/` directory to git so the rest of the pipeline is reproducible.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -d "src" && -f "src/composer.json" ]]; then
    echo "[bootstrap] src/ already contains a Laravel project. Skipping create-project."
else
    echo "[bootstrap] Creating Laravel 11 project under ./src using composer (in Docker) ..."
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "${ROOT}:/work" \
        -w /work \
        composer:2.7 \
        composer create-project laravel/laravel:^11.0 src --prefer-dist --no-interaction
fi

echo "[bootstrap] Applying overlay files (routes, .env.example, welcome view) ..."
cp -v app-overlay/routes/web.php                  src/routes/web.php
cp -v app-overlay/.env.example                    src/.env.example
mkdir -p src/resources/views
cp -v app-overlay/resources/views/welcome.blade.php src/resources/views/welcome.blade.php

# .gitkeep for the storage subtree so it survives ignore rules
mkdir -p \
    src/storage/logs \
    src/storage/framework/cache/data \
    src/storage/framework/sessions \
    src/storage/framework/views \
    src/bootstrap/cache
for d in \
    src/storage/logs/.gitkeep \
    src/storage/framework/cache/data/.gitkeep \
    src/storage/framework/sessions/.gitkeep \
    src/storage/framework/views/.gitkeep \
    src/bootstrap/cache/.gitkeep ; do
    touch "$d"
done

echo "[bootstrap] Done."
echo "[bootstrap] Next: git add src/ && git commit -m 'feat: scaffold Laravel 11 + overlay'"
