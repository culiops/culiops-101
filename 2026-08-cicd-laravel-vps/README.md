# Deploy Laravel with Docker to a VPS

Companion code for the video: a real deploy pipeline — GitHub Actions builds the image, pushes
it to GHCR, and the VPS only pulls and runs it — plus the four ways `docker compose up` reports
success while your app is quietly broken.

The bug that starts the video: you fix something, CI is green, `docker compose up -d` says done,
and the website shows the new feature. Half an hour later customers still hit the old bug —
because the queue worker is a **separate container** and it is still running the old image.
Nothing errored. It was just silently wrong.

## What you build

```
push to main → test → build image → GHCR → VPS pulls & runs → healthcheck → auto-rollback on failure
```

The VPS never builds anything. It pulls one immutable image tagged with the commit SHA, which is
also what makes rollback a one-liner.

## Two ways to run this

- **Path A — local harness ($0).** The whole stack in Docker Compose on your machine. The fastest
  way to *reproduce the failure modes*. No cloud account, no CI.
- **Path B — the real pipeline.** Terraform provisions a VPS; GitHub Actions deploys to it on
  every push.

Do Path A first to understand the traps, then Path B.

## Prerequisites

- Docker Engine 24+ and Docker Compose v2 (Path A)
- Terraform 1.5+, an AWS account and the AWS CLI configured (Path B)
- A GitHub repo you can push to, with Actions enabled (Path B)
- PHP 8.4 + Composer locally, to scaffold the app once

## The app

A stock Laravel skeleton plus the few files in `app/` (routes, a queued job, config, one
migration). Scaffold it once:

```bash
composer create-project laravel/laravel app-src
cp app/routes/web.php                    app-src/routes/web.php
cp app/app/Jobs/SendReceipt.php          app-src/app/Jobs/
cp app/config/services.php app/config/app.php  app-src/config/
cp app/database/migrations/*.php         app-src/database/migrations/
cp app/composer.json                     app-src/composer.json
# copy the Docker glue in so it is one buildable context
cp Dockerfile .dockerignore docker-compose.yml deploy.sh .env.example app-src/
cp -r docker nginx                       app-src/
cd app-src && composer install && npm install
cp .env.example .env && php artisan key:generate
```

## Path A — reproduce the four traps

```bash
export WEB_PORT=8080
docker compose up -d --build --wait          # healthy when /health returns 200
docker compose run --rm app php artisan migrate --force
curl -s localhost:8080/
```

**Trap 1 — the worker keeps running the old image.**

```bash
curl -s localhost:8080/enqueue
docker compose up -d --build --no-deps app web   # the classic mistake: web only
docker compose logs worker | tail                # still on the old version
docker compose up -d --build worker              # fix: recreate it too
```

The worker is a separate container. Recreate it with the rest, and let it finish the job it is
holding — `stop_signal: SIGTERM` plus `stop_grace_period` drain it instead of cutting it off.

**Trap 2 — `config:cache` at build time makes config null at runtime.**

```bash
docker compose exec -e STRIPE_SECRET= app \
  sh -c 'php artisan config:cache && php -r "var_dump(config(\"services.stripe.secret\"));"'
# NULL — the cache was frozen without the secret, and nothing at runtime can fix it
docker compose exec app php artisan config:cache
```

Cache config in the **entrypoint**, never in the Dockerfile. Inject secrets with `env_file`;
never bake `.env` into an image.

**Trap 3 — storage permissions are a UID mismatch, not a `chmod` problem.**

```bash
curl -s localhost:8080/store                 # works: named volume, owned by www-data
mkdir -p bad/framework/{cache,sessions,views} bad/logs bad/app/private && chmod -R 700 bad
docker run --rm -v "$PWD/bad":/s deploy-laravel-vps:local \
  sh -c 'echo x > /s/app/private/probe.txt' || echo "Permission denied"
```

Inside the container PHP runs as `www-data` — **uid 82** on Alpine, **uid 33** on Debian. A host
directory owned by uid 1000 is simply a different number, so the write is denied. `chmod 777`
makes the symptom disappear and opens those files to every process on the box. Own `storage/`
and `bootstrap/cache/` in the Dockerfile, use a **named volume** (it inherits the image's
ownership), and run non-root.

**Trap 4 — `docker compose up -d` is not zero-downtime.**

```bash
( curl -s localhost:8080/slow & )            # an 8s request in flight
docker compose up -d --force-recreate web app # recreated mid-request: 502 window
docker compose down -v
```

`--wait` plus the healthcheck gates the cutover. True zero-downtime needs two replicas behind a
proxy — that is episode 2.

Bonus, and the one you cannot undo: a one-step migration breaks the containers still running the
old code.

```bash
docker compose exec mysql sh -c \
  'mysql -ularavel -p"$MYSQL_PASSWORD" laravel -e "ALTER TABLE receipts DROP COLUMN legacy_note;"'
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/report   # 500
```

Expand and contract: one deploy stops using the column, a later deploy drops it. And run
migrations **once** from `deploy.sh` — not in the app entrypoint, where every replica races it.

## Path B — the real pipeline

```bash
ssh-keygen -t ed25519 -f deploy_key -C deploy       # a dedicated deploy key
cd terraform
cp terraform.tfvars.example terraform.tfvars        # fill in the public key, db password, image repo
terraform init && terraform apply
```

Push the app (with `composer.lock` and `package-lock.json`) to your repo, then set the three
secrets the workflow reads:

```bash
gh secret set VPS_HOST       -R <owner>/<repo> -b "$(terraform -chdir=terraform output -raw vps_public_ip)"
gh secret set DEPLOY_USER    -R <owner>/<repo> -b deploy
gh secret set DEPLOY_SSH_KEY -R <owner>/<repo> < deploy_key
```

Push to `main` and watch it: tests run, the image builds and lands in GHCR, the VPS pulls it and
`deploy.sh` gates the cutover on the healthcheck — rolling back to the previous tag if the new
release does not come up healthy. GHCR needs no personal access token; the workflow's own
`GITHUB_TOKEN` with `packages: write` is enough.

## Troubleshooting

- **`denied` pulling from GHCR on the VPS** — the package is private; the deploy job logs in to
  GHCR with `GITHUB_TOKEN` and `packages: read`.
- **The stack OOMs on a 1 GB box** — MySQL, Redis, nginx and three PHP containers do not fit in
  1 GB. Use 2 GB, add swap, or move the database off the box.
- **The first deploy takes minutes** — it pulls every base image. Later deploys reuse them.
- **`unable to find user` on build** — a trailing comment on the `USER` line in a Dockerfile is
  swallowed into the username. Put the comment on its own line.

## Cost

Path A is free. Path B on AWS is about **$0.03/hour** (a 2 GB instance plus a public IPv4), so a
couple of hours is roughly ten cents. GitHub Actions and GHCR are free tier for this.

## Cleanup

```bash
docker compose down -v                              # Path A
cd terraform && terraform destroy                   # Path B — removes the VPS and networking
gh secret delete VPS_HOST -R <owner>/<repo>         # and DEPLOY_USER, DEPLOY_SSH_KEY
```

A forgotten 2 GB instance is about $19 a month. Run `terraform destroy`.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
