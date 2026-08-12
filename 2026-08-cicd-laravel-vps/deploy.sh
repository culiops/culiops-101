#!/usr/bin/env bash
# deploy.sh — runs ON THE VPS, invoked by GitHub Actions over SSH:
#   TAG=<commit-sha> /home/deploy/deploy.sh
#
# The VPS only PULLS the CI-built image and runs it — it never builds. On failure it
# rolls back to the previous known-good image tag (which is still in the registry).
set -euo pipefail

cd "$(dirname "$0")"                       # the dir holding docker-compose.yml + .env
: "${TAG:?set TAG to the image tag (the commit SHA)}"

IMAGE_REPO=$(grep -E '^IMAGE_REPO=' .env | cut -d= -f2-)
: "${IMAGE_REPO:?put IMAGE_REPO=ghcr.io/<owner>/<repo> in .env}"
PREV=$(cat .last_good 2>/dev/null || true)

export APP_IMAGE="$IMAGE_REPO:$TAG"
echo "▶ deploying $APP_IMAGE"
docker compose pull

# Bring up the datastores first, then run migrations EXACTLY ONCE (§4.3 — never in the
# app/worker entrypoint, or every replica races the same migration).
docker compose up -d --wait mysql redis
docker compose run --rm app php artisan migrate --force

# Recreate the whole stack (app + worker + scheduler + web) and WAIT for healthy.
# --wait blocks until the healthchecks pass, so the pipeline can't claim success on a
# dead release. If it doesn't go healthy in time, roll back to the last good image.
if ! docker compose up -d --wait --wait-timeout 90; then
  echo "❌ new release did not become healthy"
  if [ -n "$PREV" ]; then
    echo "↩ rolling back to $PREV"
    export APP_IMAGE="$IMAGE_REPO:$PREV"
    docker compose up -d --wait --wait-timeout 90
  fi
  exit 1                                    # GitHub Actions job goes red → you know now
fi

echo "$TAG" > .last_good                    # record ONLY after healthy
docker image prune -f >/dev/null 2>&1 || true
echo "✅ deployed $TAG"
