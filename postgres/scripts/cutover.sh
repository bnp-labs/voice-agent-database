#!/usr/bin/env bash
# README.md §7 — point phonops-api/phonops-worker/phonops-jobs at the self-hosted
# database. Always a DIRECT connection (never a pooled endpoint — PgBouncer-style
# pooling conflicts with asyncpg's prepared statements) and the
# `postgresql+asyncpg://` scheme (the services' settings.py load DATABASE_URL with
# no scheme normalization — a plain `postgresql://` falls back to the sync psycopg2
# dialect, which isn't installed in these images).
set -euo pipefail

PG_APP="${1:-selfhost-database}"
DB_USER="${2:-admin}"     # generic role shared by every project on this cluster
DB_NAME="${3:-phonops_db}"

read -r -s -p "Postgres password for ${DB_USER}@${PG_APP}: " DB_PASSWORD
echo

# Port 5432 is the cluster proxy port the services connect on; direct, never pooled.
DATABASE_URL="postgresql+asyncpg://${DB_USER}:${DB_PASSWORD}@${PG_APP}.internal:5432/${DB_NAME}"

for app in phonops-api phonops-worker phonops-jobs; do
    echo "Setting DATABASE_URL on ${app} ..."
    fly secrets set DATABASE_URL="$DATABASE_URL" -a "$app"
done

echo
echo "Done. Verify before decommissioning the previous database (§8):"
echo "  curl https://phonops-api.fly.dev/healthz"
echo "  fly logs -a phonops-worker   # confirm clean startup, no DB connection errors"
echo "  fly logs -a phonops-jobs     # same, (all pollers share one machine)"
