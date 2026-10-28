#!/usr/bin/env bash
#
# Apply application-database schema migrations with dbmate, independently of
# the FastAPI apps (api/worker/consumer never create schema themselves).
#
#   ./migrate.sh              # apply all pending migrations (dbmate up)
#   ./migrate.sh status       # show which migrations are applied/pending
#   ./migrate.sh down         # roll back the most recent migration
#   ./migrate.sh new <name>   # scaffold a new migration file under db/migrations
#
# Scope: this manages the APPLICATION database (orders_api_main, `crane` schema) via
# APP_DATABASE_URL. DBOS manages its own system database separately, on
# DBOS.launch() - dbmate does not touch it.

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v dbmate >/dev/null 2>&1; then
  echo "error: dbmate not found on PATH (install the standalone binary)" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "error: .env not found next to migrate.sh" >&2
  exit 1
fi

# Migrations run on the host, so APP_DATABASE_URL here is the host-side URL
# (localhost), exactly as the host apps use it.
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${APP_DATABASE_URL:?APP_DATABASE_URL must be set in .env}"

# dbmate reads DATABASE_URL. Normalize the scheme to postgres:// and force
# sslmode=disable (local Postgres has no TLS).
url="$(printf '%s' "$APP_DATABASE_URL" | sed -E 's#^postgresql://#postgres://#')"
case "$url" in
  *\?*) url="${url}&sslmode=disable" ;;
  *)    url="${url}?sslmode=disable" ;;
esac
export DATABASE_URL="$url"

# Default to `up` when no subcommand is given.
if [[ $# -eq 0 ]]; then
  set -- up
fi

# --no-dump-schema: skip writing db/schema.sql (that would need pg_dump on PATH).
exec dbmate --migrations-dir "./db/migrations" --no-dump-schema "$@"
