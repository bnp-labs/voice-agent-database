#!/usr/bin/env bash
# README.md §4 — mandatory before migrating any real data.
#
# This org's 6PN private networking to app-declared ports has already
# failed once this session: vocetto-api's own port was unreachable via
# `.internal` from other apps (DNS resolved fine, raw TCP connect timed
# out), confirmed from multiple apps, multiple times — only resolved by
# switching those apps to public URLs instead. Postgres clusters may use a
# different private-routing mechanism than plain apps, but this script
# exists specifically because that should be verified, not assumed.
set -euo pipefail

PG_APP="${1:-voxai-pg-selfhosted}"
TEST_FROM_APP="${2:-vocetto-api}"

echo "Testing TCP connectivity from ${TEST_FROM_APP} to ${PG_APP}.internal:5432 ..."
echo

fly ssh console -a "$TEST_FROM_APP" -C "python3 -c \"
import socket
try:
    s = socket.create_connection(('${PG_APP}.internal', 5432), timeout=8)
    print('OK: TCP connect succeeded')
    s.close()
except Exception as e:
    print('FAILED:', e)
    raise SystemExit(1)
\""

echo
echo "If this failed: STOP. Do not proceed to migrate (§6) or cutover (§7) —"
echo "the .internal hostnames this guide uses won't work. Same failure mode"
echo "as vocetto-api's own 6PN issue this session — needs a different"
echo "connectivity approach before going further."
