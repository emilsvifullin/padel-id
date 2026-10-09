#!/usr/bin/env bash
# Recreates the local development database and applies the shim + all migrations.
set -euo pipefail
PGHOST=${PGHOST:-/var/tmp/pgdev}
PGPORT=${PGPORT:-54329}
DB=${DB:-padelid}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST PGPORT PGUSER=postgres
psql -q -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/scripts/db/shim.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null || { echo "FAILED: $f"; exit 1; }
done
echo "local database $DB ready"
