#!/usr/bin/env bash
# Rebuild a throwaway LOCAL database from scratch: Supabase shim, every
# migration in order, and the seed. Refuses anything that looks like a
# Supabase project because it drops the public schema first.
#
#   DATABASE_URL=postgresql://postgres@127.0.0.1:5432/pdspan_check scripts/db-reset.sh
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL to a local Postgres database}"
case "$DATABASE_URL" in
  *supabase.co*|*supabase.com*|*pooler.supabase*) echo "refusing to run against a Supabase project" >&2; exit 1 ;;
esac
cd "$(dirname "$0")/.."

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
drop schema if exists public cascade;
drop schema if exists auth cascade;
drop schema if exists storage cascade;
create schema public;
SQL

for f in supabase/dev/shim.sql supabase/migrations/*.sql supabase/seed.sql; do
  echo "== $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f"
done
