# Multi-stage build for a Laravel app image. The build tools (composer, node) live
# ONLY in the builder stages; the runtime image is a slim php:8.4-fpm with just the
# compiled result. Tagged by commit SHA in CI (never :latest) so it can be rolled back.

# ── stage 1: PHP dependencies (no dev) ───────────────────────────────────────
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
# --no-scripts: artisan isn't available yet (no full app); scripts run at runtime.
RUN composer install --no-dev --no-scripts --optimize-autoloader --no-interaction --prefer-dist

# ── stage 2: front-end assets ────────────────────────────────────────────────
FROM node:22-alpine AS assets
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ── stage 3: runtime — slim, pinned, non-root ────────────────────────────────
FROM php:8.4-fpm-alpine AS runtime

# install-php-extensions: the robust way to add extensions on the official image.
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN install-php-extensions pdo_mysql opcache redis bcmath pcntl \
 && apk add --no-cache curl                       # curl = the container healthcheck

WORKDIR /var/www/app

# App code first, then the built artifacts from the builder stages. --chown so the
# files are owned by www-data (uid 82 on Alpine) — the user php-fpm runs as.
COPY --chown=www-data:www-data . .
COPY --from=vendor --chown=www-data:www-data /app/vendor        ./vendor
COPY --from=assets --chown=www-data:www-data /app/public/build  ./public/build

# The ONLY two dirs Laravel must write at runtime. Own them (this is the §3 fix —
# a UID that can actually write, instead of chmod 777). Everything else stays
# read-only. storage/ is a named volume in compose; the skeleton + ownership here
# seed that volume on first run.
RUN mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views \
             storage/logs storage/app/private bootstrap/cache \
 && chown -R www-data:www-data storage bootstrap/cache

# opcache tuned for production (validate_timestamps=0: bytecode never re-checked —
# a new image is the ONLY way new code takes effect, which is exactly what we want).
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/entrypoint
# never run the app as root (Dockerfile has no inline comments — keep this on its own line)
USER www-data
ENTRYPOINT ["entrypoint"]
CMD ["php-fpm"]
