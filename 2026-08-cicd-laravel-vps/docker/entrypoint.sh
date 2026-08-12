#!/bin/sh
# entrypoint — runs when the container STARTS (not at build time). This is where
# config/route caches are built: at build time the real env isn't present yet, and
# caching then would freeze the build machine's config into the image (see §4.2).
# Secrets arrive at runtime via compose env_file, so cache here — after env exists.
set -e

# Rebuild the config cache from the runtime environment. AFTER this, env() outside
# config/*.php returns null — the app must read config(), never env() (§4.2).
php artisan config:cache
php artisan route:cache
php artisan event:cache

# NOTE: migrations are deliberately NOT run here. This entrypoint runs in EVERY
# container (app, worker, scheduler) and scales with replicas — running migrate here
# means N containers racing the same migration (§4.3). Migrate runs ONCE in deploy.sh.

exec "$@"
