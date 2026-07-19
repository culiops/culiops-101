#!/usr/bin/env bash
# cleanup.sh — CuliOps Lab Cleanup (backup restore drill)
# ⚠️  Removes the lab's Docker container + volume and all local backup artifacts.
# Everything here is LOCAL — there are no cloud resources and no charges to stop.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "🧹 CuliOps Lab Cleanup — production backup drill"
echo "==============================================="
echo ""
echo "This will delete:"
echo "  - Docker container + volume: culiops-backup-lab-db (via docker compose down -v)"
echo "  - Local backup artifacts:    backups/ (*.dump, *.sql, *.gz, *.gpg)"
echo "  - Local passphrase file:     .gpgpass"
echo ""
read -rp "Continue? (y/N) " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

echo ""
echo "→ Stopping and removing container + volume..."
docker compose down -v 2>/dev/null || echo "  (compose stack already down)"

echo "→ Removing local backup artifacts..."
rm -rf backups/ .gpgpass 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ Cleanup complete!${NC}"
echo -e "💰 Cost saved: ${YELLOW}\$0${NC} — this lab is 100% local (no cloud resources)."
echo ""
echo "Double-check nothing lingers:"
echo "  docker ps -a | grep culiops-backup-lab   # should be empty"
echo "  docker volume ls | grep backup-restore   # should be empty"
