#!/usr/bin/env bash
#
# Carve this project's slice out of the machine's SHARED local dev stack:
# its databases + schema, its S3 bucket, its Kafka topic.
#
#   ./setup-devstack.sh          # create what's missing (safe to re-run)
#   ./setup-devstack.sh --check  # only report what exists, change nothing
#
# The shared stack (Postgres, Silo/S3, Redpanda, Mailpit, Grafana) is started
# once per machine from its own directory - see the local-dev-stack skill - and
# is shared by every repo. Compose used to do this work automatically when the
# backing services lived in this project; now that they don't, it lives here.
#
# Every step is idempotent, so run it again after `docker compose down -v` on
# the shared stack, or whenever you're unsure.

set -euo pipefail
cd "$(dirname "$0")"

# Container names in the shared stack are fixed (only one copy of it ever runs),
# which is what lets this script address them directly.
PG_CONTAINER="${PG_CONTAINER:-postgres}"
S3_CONTAINER="${S3_CONTAINER:-s3}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-redpanda}"

# Keep these equal to constants.py (BUCKET_NAME, KAFKA_TOPIC) and the database
# names in .env / docker-compose.yml.
BUCKET_NAME="orders-bucket"
KAFKA_TOPIC="order-events"

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

if [[ ! -f .env ]]; then
  echo "error: .env not found - copy the template: cp .env.example .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${POSTGRES_USER:?POSTGRES_USER must be set in .env}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set in .env}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set in .env}"

# --- the shared stack must be up ---------------------------------------------
missing=()
for c in "$PG_CONTAINER" "$S3_CONTAINER" "$KAFKA_CONTAINER"; do
  docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true || missing+=("$c")
done

if (( ${#missing[@]} )); then
  cat >&2 <<MSG
error: the shared dev stack isn't running - missing container(s): ${missing[*]}

Start it first (it is shared by every repo, so this is a one-time thing):

    cd ~/Developer/docker && docker-compose up -d

Then run this script again.
MSG
  exit 1
fi
echo "==> shared dev stack is up ($PG_CONTAINER, $S3_CONTAINER, $KAFKA_CONTAINER)"

if [[ "$CHECK_ONLY" == true ]]; then
  echo "--- databases ---"
  docker exec -i "$PG_CONTAINER" psql -U "$POSTGRES_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datname LIKE 'orders_api%' ORDER BY 1"
  echo "--- buckets ---"
  docker exec -i "$S3_CONTAINER" mc ls local 2>/dev/null || echo "(no mc alias yet)"
  echo "--- topics ---"
  docker exec -i "$KAFKA_CONTAINER" rpk topic list
  exit 0
fi

# --- databases, schema, search_path ------------------------------------------
# init-db.sql is written to be re-runnable (CREATE DATABASE is guarded with
# \gexec), so ON_ERROR_STOP=1 is safe: anything that errors is a real problem.
echo "==> applying backing/init-db.sql"
docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  < backing/init-db.sql

# --- S3 bucket ----------------------------------------------------------------
# The alias persists in the container's config, but set it every time so this
# works on a freshly recreated stack too. localhost inside the s3 container is
# Silo itself.
echo "==> ensuring bucket $BUCKET_NAME"
docker exec -i "$S3_CONTAINER" mc alias set local \
  "http://localhost:9000" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null
docker exec -i "$S3_CONTAINER" mc mb --ignore-existing "local/$BUCKET_NAME"

# --- Kafka topic ---------------------------------------------------------------
# The producer would auto-create this, but creating it up front means Redpanda
# Console shows it before the first order is submitted.
echo "==> ensuring topic $KAFKA_TOPIC"
docker exec -i "$KAFKA_CONTAINER" rpk topic create "$KAFKA_TOPIC" 2>&1 \
  | grep -v 'TOPIC_ALREADY_EXISTS' || true

echo
echo "done. Next:"
echo "  ./migrate.sh                   # app-DB schema (dbmate)"
echo "  docker compose up -d --build   # the three app services"
