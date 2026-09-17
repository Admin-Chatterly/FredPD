#!/usr/bin/env bash
# Validate the schema against a throwaway LOCAL Postgres: rebuilds it with
# scripts/db-reset.sh, then runs the assertions in supabase/dev/checks.sql.
#
#   DATABASE_URL=postgresql://postgres@127.0.0.1:5432/pdspan_check scripts/db-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/db-reset.sh
echo "== supabase/dev/checks.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f supabase/dev/checks.sql
echo "db-check: OK"
