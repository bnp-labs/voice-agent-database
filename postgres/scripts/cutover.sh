#!/usr/bin/env bash
# README.md §7 — point voxai-api/voxai-worker/voxai-jobs at the new
# self-hosted database. Same discipline established earlier this session
# for the MPG cluster: DIRECT connection (never a pooled endpoint —
# PgBouncer-style pooling was already found to conflict with asyncpg's
# prepared statements), and the `postgresql+asyncpg://` scheme (all three
# services' config/settings.py load DATABASE_URL with no scheme
# normalization — a plain `postgresql://` silently falls back to the sync
# psycopg2 dialect, which isn't installed in these images).
set -euo pipefail

PG_APP="${1:-voxai-pg-selfhosted}"
DB_USER="${2:-voice_agent}"
DB_NAME="${3:-voice_agent}"

read -r -s -p "Postgres password for ${DB_USER}@${PG_APP}: " DB_PASSWORD
echo

DATABASE_URL="postgresql+asyncpg://${DB_USER}:${DB_PASSWORD}@${PG_APP}.internal:5432/${DB_NAME}"

for app in voxai-api voxai-worker voxai-jobs; do
    echo "Setting DATABASE_URL on ${app} ..."
    fly secrets set DATABASE_URL="$DATABASE_URL" -a "$app"
done

echo
echo "Done. Verify before touching MPG (§8):"
echo "  curl https://voxai-api.fly.dev/healthz"
echo "  fly logs -a voxai-worker   # confirm clean startup, no DB connection errors"
echo "  fly logs -a voxai-jobs     # same, across all 9 process groups"
