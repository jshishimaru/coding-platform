#!/bin/bash

# ============================================================
# Database Migration Script
# ============================================================
# Applies any SQL migrations in config/migrations/ to the running
# postgres container (in filename order).
#
# Use this when upgrading an existing database — init.sql only
# runs on first boot with an empty data directory.
#
# Every migration in config/migrations/*.sql MUST be idempotent
# (safe to re-run). All platform migrations are written this way.
#
# Usage:
#   chmod +x scripts/migrate.sh
#   ./scripts/migrate.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATIONS_DIR="$PROJECT_ROOT/config/migrations"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
success() { echo -e "${GREEN}✓${NC} $1"; }
info()    { echo -e "${CYAN}→${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
fail()    { echo -e "${RED}✗${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Coding Platform — Database Migrations"
echo "═══════════════════════════════════════════════════"
echo ""

if ! docker compose ps postgres 2>/dev/null | grep -q 'running\|Up'; then
  fail "postgres container is not running. Start the stack with ./scripts/run.sh first."
  exit 1
fi

if [ ! -d "$MIGRATIONS_DIR" ]; then
  warn "No migrations directory at $MIGRATIONS_DIR — nothing to do."
  exit 0
fi

shopt -s nullglob
MIGRATIONS=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob

if [ "${#MIGRATIONS[@]}" -eq 0 ]; then
  warn "No .sql files in $MIGRATIONS_DIR — nothing to do."
  exit 0
fi

info "Found ${#MIGRATIONS[@]} migration(s)"
for f in "${MIGRATIONS[@]}"; do
  NAME="$(basename "$f")"
  info "Applying $NAME..."
  if docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-coding_platform}" \
       -v ON_ERROR_STOP=1 < "$f" >/dev/null 2>&1; then
    success "$NAME applied"
  else
    fail "$NAME failed — re-running verbosely for diagnostics:"
    docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-coding_platform}" \
      -v ON_ERROR_STOP=1 < "$f" || true
    exit 1
  fi
done

echo ""
success "All migrations applied successfully."
echo ""
