#!/usr/bin/env bash
# README.md §10 — confirm backups are actually landing, not just that
# --enable-backups was passed at creation time. Run this periodically, not
# just once at setup.
set -euo pipefail

PG_APP="${1:-voxai-pg-selfhosted}"

echo "=== Recent backups for ${PG_APP} ==="
fly postgres backup list -a "$PG_APP"

echo
echo "An unverified backup isn't a backup — periodically also do a real"
echo "restore drill (fly postgres backup restore) into a throwaway cluster"
echo "and confirm the data actually comes back, not just that a backup"
echo "object exists."
