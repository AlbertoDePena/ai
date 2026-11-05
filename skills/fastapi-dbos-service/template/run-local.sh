#!/usr/bin/env bash
#
# Run one app process directly on the host (no container), against the machine's
# shared local dev stack.
#
#   ./run-local.sh infra     # start the SHARED dev stack (Postgres, S3, Kafka, ...)
#   ./run-local.sh api       # FastAPI API + dashboard on :8000
#   ./run-local.sh worker    # DBOS queue worker (FastAPI + /health) on :8001
#   ./run-local.sh consumer  # DBOS Kafka consumer (FastAPI + /health) on :8002
#
# `docker compose up -d --build` runs the three app services in containers
# instead; use this when you want one process on the host (reloading, a
# debugger, breakpoints) and everything else in Docker. Env comes from .env next
# to this script - its host-side endpoints (localhost, 19092) are what make that
# work.
#
# `infra` is a convenience wrapper: the backing services are NOT part of this
# project, they are the shared stack that every repo uses, so this just runs
# `up -d` in that stack's directory ($DEVSTACK_DIR, default ~/Developer/docker).
# Running it when the stack is already up is a no-op.

set -euo pipefail

cd "$(dirname "$0")"

# Where the shared dev stack's compose file lives. Override in .env or the
# environment if yours is somewhere else.
DEVSTACK_DIR="${DEVSTACK_DIR:-$HOME/Developer/docker}"

if [[ ! -f .env ]]; then
  echo "error: .env not found - copy the template: cp .env.example .env" >&2
  exit 1
fi

# Load .env, exporting every var it defines.
set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ "${1:-}" == "infra" ]]; then
  if [[ ! -f "$DEVSTACK_DIR/docker-compose.yml" ]]; then
    echo "error: no docker-compose.yml in $DEVSTACK_DIR" >&2
    echo "       set DEVSTACK_DIR to the shared dev stack's directory" >&2
    exit 1
  fi
  cd "$DEVSTACK_DIR"
  # Compose ships either as a `docker` plugin (`docker compose`) or as a
  # standalone `docker-compose` binary; which one is installed varies by
  # machine, so detect rather than assume.
  if docker compose version >/dev/null 2>&1; then
    exec docker compose up -d
  elif command -v docker-compose >/dev/null 2>&1; then
    exec docker-compose up -d
  else
    echo "error: neither 'docker compose' nor 'docker-compose' found on PATH" >&2
    exit 1
  fi
fi

# Create the virtualenv and install requirements on first run (no-op after).
if [[ ! -d .venv ]]; then
  echo "==> .venv not found; creating it and installing requirements (first run)" >&2
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt
fi

case "${1:-}" in
  api)
    exec .venv/bin/uvicorn api:app --host 0.0.0.0 --port 8000 --reload
    ;;
  worker)
    exec .venv/bin/uvicorn worker:app --host 0.0.0.0 --port 8001 --reload
    ;;
  consumer)
    exec .venv/bin/uvicorn consumer:app --host 0.0.0.0 --port 8002 --reload
    ;;
  *)
    echo "usage: $0 {infra|api|worker|consumer}" >&2
    exit 2
    ;;
esac
