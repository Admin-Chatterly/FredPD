#!/usr/bin/env bash
# End-to-end check of the data layer through a real PostgREST. Needs a LOCAL
# Postgres (rebuilt from the seed by scripts/db-reset.sh) and a PostgREST
# binary (POSTGREST_BIN, default: `postgrest` on PATH).
#
#   DATABASE_URL=postgresql://postgres@127.0.0.1:5432/pdspan_check scripts/postgrest-check.sh
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL to a local Postgres database}"
POSTGREST_BIN="${POSTGREST_BIN:-postgrest}"
PORT="${POSTGREST_PORT:-3100}"
JWT_SECRET="${PGRST_JWT_SECRET:-local-dev-secret-at-least-32-characters-long}"
USER_ID="00000000-0000-4000-8000-000000000001"
cd "$(dirname "$0")/.."

scripts/db-reset.sh

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
do \$\$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login;
  end if;
end \$\$;
grant anon, authenticated to authenticator;
insert into auth.users (id, email, raw_user_meta_data)
values ('$USER_ID', 'tester@example.com', '{"callsign": "Tester"}')
on conflict (id) do nothing;
SQL

# Same server, but connect as the authenticator role.
PGRST_DB_URI="$(echo "$DATABASE_URL" | sed -E 's#://[^@/]*@#://authenticator@#; s#://([^@/]+)/#://authenticator@\1/#')"
export PGRST_DB_URI PGRST_DB_SCHEMAS=public PGRST_DB_ANON_ROLE=anon PGRST_JWT_SECRET="$JWT_SECRET"
export PGRST_SERVER_PORT="$PORT" PGRST_SERVER_HOST=127.0.0.1 PGRST_LOG_LEVEL=error
"$POSTGREST_BIN" > /dev/null 2>&1 &
PGRST_PID=$!
trap 'kill $PGRST_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then break; fi
  sleep 0.5
done

POSTGREST_URL="http://127.0.0.1:$PORT" CHECK_USER_ID="$USER_ID" PGRST_JWT_SECRET="$JWT_SECRET" \
  pnpm exec tsx supabase/dev/postgrest-check.ts
