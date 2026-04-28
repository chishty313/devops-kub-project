# syntax=docker/dockerfile:1.7
#
# Production-ready, multi-stage Dockerfile for a Laravel 11 application.
#
# Image layout:
#   Stage 1 (composer-deps): resolves PHP dependencies with Composer 2 against the
#                            Laravel source under ./src, in two passes so the
#                            vendor/ layer caches well.
#   Stage 2 (runtime)      : php:8.3-fpm-alpine + nginx + supervisor in a single
#                            container, runs as a non-root user, exposes :8080.
#
# Build:
#   docker build -t <docker-hub-user>/laravel-k8s:1.0.0 .
# Run (test):
#   docker run --rm -p 8080:8080 \
#       -e APP_ENV=local -e APP_DEBUG=true \
#       -e APP_KEY="$(openssl rand -base64 32 | sed 's/^/base64:/')" \
#       <docker-hub-user>/laravel-k8s:1.0.0
#

###############################################################################
# Stage 1 — Composer dependencies
###############################################################################
FROM composer:2.7 AS composer-deps

WORKDIR /app

# 1) Copy only the manifest first so this layer is cached as long as composer.json/lock don't change
COPY src/composer.json src/composer.lock ./

# 2) Resolve production dependencies. --no-scripts because artisan isn't in the image yet.
RUN composer install \
        --no-dev \
        --no-interaction \
        --no-progress \
        --no-scripts \
        --prefer-dist \
        --optimize-autoloader

# 3) Now bring in the rest of the source and finalise autoloader (run scripts now that artisan is present)
COPY src/ ./
RUN composer dump-autoload --optimize --classmap-authoritative \
 && composer run-script post-autoload-dump || true


###############################################################################
# Stage 2 — Runtime: nginx + php-fpm 8.3 (alpine), non-root
###############################################################################
FROM php:8.3-fpm-alpine AS runtime

# ---- OS packages ----
# Runtime libs we keep, plus build deps in a virtual package we strip again.
RUN apk add --no-cache \
        nginx supervisor curl bash tzdata \
        icu-libs libpng libjpeg-turbo libwebp freetype libzip oniguruma sqlite-libs \
 && apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        icu-dev libpng-dev libjpeg-turbo-dev libwebp-dev freetype-dev libzip-dev oniguruma-dev sqlite-dev linux-headers \
 && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
 && docker-php-ext-install -j"$(nproc)" \
        pdo pdo_mysql pdo_sqlite mbstring exif pcntl bcmath gd zip intl opcache \
 && apk del .build-deps \
 && rm -rf /var/cache/apk/*

# ---- Non-root user ----
ARG UID=1000
ARG GID=1000
RUN addgroup -g ${GID} app \
 && adduser -D -u ${UID} -G app -h /var/www/html -s /bin/sh app

WORKDIR /var/www/html

# ---- Copy application from composer stage ----
COPY --from=composer-deps --chown=app:app /app/ /var/www/html/

# ---- Container configuration files ----
COPY docker/php.ini             /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php-fpm.conf        /usr/local/etc/php-fpm.d/zz-app.conf
COPY docker/nginx.conf          /etc/nginx/nginx.conf
COPY docker/supervisord.conf    /etc/supervisord.conf
COPY docker/entrypoint.sh       /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
 && mkdir -p /var/log/supervisor /run/nginx /var/lib/nginx/tmp /var/lib/nginx/logs /var/log/php-fpm \
 && chown -R app:app \
        /var/www/html \
        /var/log/supervisor /var/log/php-fpm \
        /run/nginx /var/lib/nginx /etc/nginx \
 && chmod -R ug+rwX /var/www/html/storage /var/www/html/bootstrap/cache

# ---- Build-time Laravel optimisations (route + view cache only) ----
# config:cache is intentionally NOT run here because runtime config (APP_KEY, DB_*, etc.)
# is injected via env. We run config:cache in entrypoint.sh once env vars are present.
RUN su app -s /bin/sh -c "php artisan route:cache && php artisan view:cache" || true

USER app

# nginx in this image listens on 8080 (non-privileged, allows non-root)
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
