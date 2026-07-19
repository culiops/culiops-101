# CuliOps lab — production backup drill (PostgreSQL 18, local Docker)
# Story: a backup you never restored is not a backup. Then: compress + encrypt at rest.
# Usage:  make up  →  make seed  →  make drill   (then explore: sizes / backup-enc / restore-enc)

DB       ?= shop
DBUSER   ?= culiops
COMPOSE  ?= docker compose
EXEC      = $(COMPOSE) exec -T db
PSQL      = $(EXEC) psql -U $(DBUSER) -d $(DB) -v ON_ERROR_STOP=1
DUMP      = $(EXEC) pg_dump -U $(DBUSER) $(DB)
BDIR      = backups
GPGPASS  ?= .gpgpass

.DEFAULT_GOAL := help
.PHONY: help up down ps logs seed count backup backup-plain backup-gz backup-enc \
        sizes peek disaster restore restore-enc verify drill init clean

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: ## Start Postgres 18 and wait until healthy
	$(COMPOSE) up -d
	@echo "waiting for postgres to be healthy..."
	@for i in $$(seq 1 30); do \
	  status=$$($(COMPOSE) ps -q db | xargs docker inspect -f '{{.State.Health.Status}}' 2>/dev/null); \
	  [ "$$status" = "healthy" ] && { echo "✓ db healthy"; exit 0; }; sleep 2; \
	done; echo "✗ db did not become healthy" >&2; exit 1

down: ## Stop and remove the container + volume
	$(COMPOSE) down -v

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Tail db logs
	$(COMPOSE) logs -f db

seed: ## Load the golden state (5000 orders)
	$(PSQL) < sql/seed.sql

count: ## Count rows in orders (the golden number)
	@$(PSQL) -tAc "SELECT count(*) FROM orders" | xargs echo "orders rows:"

# ── Part 1: the restore drill ────────────────────────────────────────────────
backup: ## Backup in Postgres custom format (compressed, parallel-restore capable)
	@mkdir -p $(BDIR)
	@$(DUMP) -Fc > $(BDIR)/orders.dump
	@echo "✓ wrote $(BDIR)/orders.dump ($$(du -h $(BDIR)/orders.dump | cut -f1))"

disaster: ## Simulate total data loss (DROP TABLE orders)
	@echo "💥 dropping table orders (tay có hơi run)..."
	@$(PSQL) -c "DROP TABLE IF EXISTS orders CASCADE"
	@echo "✓ data gone."

restore: ## Restore from the custom-format dump — TIMED (this is your real RTO)
	@start=$$(date +%s); \
	 $(EXEC) pg_restore -U $(DBUSER) -d $(DB) --no-owner --clean --if-exists < $(BDIR)/orders.dump; \
	 end=$$(date +%s); \
	 echo "⏱  RTO (restore time): $$((end - start))s"

verify: ## Verify restored row count matches the golden state
	@$(PSQL) -tAc "SELECT count(*) FROM orders" | xargs echo "restored rows:"

drill: ## Full drill: backup → count → DISASTER → restore(timed) → verify
	@echo "── 1. backup ──";        $(MAKE) -s backup
	@echo "── 2. golden count ──";  $(MAKE) -s count
	@echo "── 3. DISASTER ──";      $(MAKE) -s disaster
	@echo "── 4. restore (timed) ──"; $(MAKE) -s restore
	@echo "── 5. verify ──";        $(MAKE) -s verify
	@echo "✅ drill done. Did 'restored rows' match 'golden count'? If yes, you have a backup. If no, you had faith."

# ── Part 2: compression (the silent storage bill) ────────────────────────────
backup-plain: ## Raw SQL dump (uncompressed — the expensive one)
	@mkdir -p $(BDIR); $(DUMP) > $(BDIR)/orders.sql
	@echo "✓ $(BDIR)/orders.sql ($$(du -h $(BDIR)/orders.sql | cut -f1))"

backup-gz: ## Compressed in the pipeline (never touches disk raw)
	@mkdir -p $(BDIR); $(DUMP) | gzip > $(BDIR)/orders.sql.gz
	@echo "✓ $(BDIR)/orders.sql.gz ($$(du -h $(BDIR)/orders.sql.gz | cut -f1))"

sizes: ## Compare backup sizes side by side
	@echo "size    file"; ls -lh $(BDIR)/orders.* 2>/dev/null | awk '{printf "%-7s %s\n", $$5, $$9}'

# ── Part 3: encryption at rest ───────────────────────────────────────────────
init: ## Create a local passphrase file (DEMO ONLY — real key lives in KMS/Vault, NOT next to the backup)
	@if [ ! -f $(GPGPASS) ]; then \
	  head -c 24 /dev/urandom | base64 > $(GPGPASS); chmod 600 $(GPGPASS); \
	  echo "✓ wrote $(GPGPASS) (gitignored). ⚠️  In production the key must NOT sit next to the backup."; \
	else echo "$(GPGPASS) already exists"; fi

backup-enc: init ## Dump → gzip → gpg (encrypted at rest)
	@mkdir -p $(BDIR)
	@$(DUMP) | gzip | gpg --batch --yes --symmetric --cipher-algo AES256 \
	   --passphrase-file $(GPGPASS) -o $(BDIR)/orders.sql.gz.gpg
	@echo "✓ $(BDIR)/orders.sql.gz.gpg ($$(du -h $(BDIR)/orders.sql.gz.gpg | cut -f1))"

peek: ## Try to read the encrypted file with your eyes (you can't — that's the point)
	@echo "first bytes of the encrypted backup:"; \
	 head -c 80 $(BDIR)/orders.sql.gz.gpg | od -An -tx1 | head -3

restore-enc: ## Decrypt → gunzip → restore — TIMED. Proves the WHOLE round-trip, not just encrypt.
	@$(MAKE) -s disaster
	@start=$$(date +%s); \
	 gpg --batch --yes --decrypt --passphrase-file $(GPGPASS) $(BDIR)/orders.sql.gz.gpg \
	   | gunzip | $(PSQL); \
	 end=$$(date +%s); \
	 echo "⏱  RTO (encrypted restore): $$((end - start))s"
	@$(MAKE) -s verify

clean: ## Tear everything down (calls cleanup.sh)
	@bash cleanup.sh
