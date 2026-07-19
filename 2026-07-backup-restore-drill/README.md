# A backup you never restored is not a backup

Companion code for the video: a **production backup drill** you run entirely on your own
machine — back up a database, destroy it, restore it (timed), then add the two things every
tutorial skips: **compression** and **encryption at rest**. No cloud, no cost.

The stack is **PostgreSQL 18** in Docker, but the principles apply to anything you back up
(MySQL, Mongo, files, volumes) — Postgres is just the most common example.

## Prerequisites

- **Docker** + **Docker Compose**
- **`gpg`** and **`gzip`** (preinstalled on most Linux/macOS) — only for the encryption part
- **`make`**

## Steps

```bash
cp .env.example .env      # optional — defaults work

make up                   # start PostgreSQL 18, wait until healthy
make seed                 # load the "golden state": 5000 orders
make drill                # backup -> count -> DISASTER (drop) -> restore (TIMED) -> verify

# Part 2 — compression (the storage bill nobody looks at)
make backup-plain         # raw SQL dump
make backup-gz            # pg_dump | gzip
make sizes                # compare side by side

# Part 3 — encryption at rest (and prove the round-trip)
make backup-enc           # dump | gzip | gpg (AES256)
make peek                 # try to read it -> binary, unreadable
make restore-enc          # decrypt | gunzip | restore, TIMED + verify

make clean                # tear everything down (required)
```

`make drill` prints your real **RTO** (restore time) and checks the restored row count against
the golden state. **Match = you have a backup. No match = you had faith.**

## Troubleshooting

- **Port already in use:** the container publishes `55432` by default. Change `HOST_PORT` in
  `.env` if something else holds it.
- **`make restore-enc` can't find the key:** run `make backup-enc` first — it creates a local
  `.gpgpass`. In production the key must live in KMS / Vault, **never next to the backup**.
- **`trust` auth in `docker-compose.yml`:** this is a local throwaway lab. Never use trust auth
  in production.

## Cost

**$0** — everything runs locally in Docker. `make clean` just leaves your machine tidy; there are
no cloud resources to bill.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
