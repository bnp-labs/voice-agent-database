#!/usr/bin/env bash
# README.md §6 — migrate data from the existing Fly Managed Postgres
# cluster into the self-hosted one, using flyctl's built-in importer
# (schema + data in one step, runs as a one-off Fly migration machine).
#
# Usage: ./migrate-from-mpg.sh "postgresql://voice_agent:<password>@direct.w86750817lnr3pk4.flympg.net/voice_agent"
set -euo pipefail

SOURCE_URI="${1:?Usage: $0 <mpg-source-uri>}"
PG_APP="${2:-voxai-pg-selfhosted}"

echo "⚠️  This imports INTO ${PG_APP} FROM the URI you provided."
echo "    Confirm §4 (verify-connectivity.sh) has already passed before"
echo "    running this — do not import into a cluster you haven't confirmed"
echo "    is actually reachable by the apps that will use it."
echo
read -r -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

fly postgres import "$SOURCE_URI" -a "$PG_APP"

echo
echo "Import finished. Spot-check before trusting it:"
echo "  fly postgres connect -a ${PG_APP}"
echo "  SELECT count(*) FROM workspaces;"
echo "  SELECT id, name, settings->>'default_timezone' FROM workspaces;"
echo "Compare row counts / known values against the source MPG cluster before"
echo "proceeding to cutover (§7)."
