---
name: local-dev-stack
description: Set up and connect repos to the ONE shared local development stack — a single docker-compose project (Postgres 17, Silo for S3, Redpanda + Console, Mailpit, otel-lgtm/Grafana) that runs once per machine and is shared by every application. Use whenever the user wants local backing services, says "set up docker compose", "add the dev stack", "I need Postgres and Kafka locally", "spin up the local containers", "add S3/MinIO locally", "add a local SMTP server", "add Grafana/OTel locally", or needs a new app wired to Postgres/S3/Kafka/SMTP/OTel for development. Also use to give an app its own database, bucket and topics inside the shared stack, or to retire a repo's redundant per-repo compose file in favour of the shared one. Do NOT use for production/deployment compose files or for Dockerfiles that build the app itself.
---

# Shared local dev stack

There is **one** local dev stack per machine. It is started once and shared by
every repo. Do not scaffold a copy of it into a repo, and do not add app
services to it.

Default location: `~/Developer/docker`. Applications isolate themselves
logically inside it — their own Postgres database, their own S3 bucket, their
own Kafka topics — not with their own containers.

Files in `template/`: `docker-compose.yml`, `.env.example`, `README.md`. They
are literal — no placeholders to substitute. Every `${...}` in the compose file
is a compose interpolation resolved from `.env` at runtime; leave it alone.

## What the stack contains

| Service | Container | Host ports |
|---|---|---|
| Postgres 17-alpine, persisted | `postgres` | 5432 |
| Silo — S3-compatible object storage | `s3` | 9000 API, 9001 console |
| Redpanda (Kafka-compatible) | `redpanda` | 19092 |
| Redpanda Console | `redpanda_console` | 8080 |
| Mailpit — SMTP sink + web UI | `mailpit` | 1025 SMTP, 8025 UI |
| otel-lgtm — Grafana/Loki/Tempo/Prometheus, persisted | `grafana` | 3000 UI, 4317 OTLP gRPC, 4318 OTLP HTTP |

Ports and container names are fixed, not parameterized. That is the point of a
single stack: every repo on the machine can hard-code `localhost:5432` and
`localhost:19092` and be right.

## Making sure the stack exists and is up

1. **Find it.** Check `~/Developer/docker/docker-compose.yml`, then
   `docker ps --format '{{.Names}}'` for `postgres`, `s3`, `redpanda`,
   `mailpit`, `grafana`. If the containers are already running, there is
   nothing to install — skip to *Onboarding an app*.

2. **Create it only if it is missing.** Copy the three `template/` files into
   `~/Developer/docker/` (confirm the directory with the user if their layout
   differs), and copy `.env.example` to `.env`. If a `docker-compose.yml`
   already lives there, read it and merge — report what you are changing before
   you change it; never overwrite it blind.

3. **Start it.** `docker-compose up -d` from that directory, then
   `docker-compose ps`. `up -d` is idempotent — re-running it against an
   already-healthy stack is a no-op, so it is always safe.
   - Compose here is the standalone binary: `docker-compose`, not
     `docker compose`.
   - A port already in use means something non-stack holds it. Grafana's 3000
     is the usual culprit (a Node or Vite dev server). Stop the other process
     rather than moving the stack's port — repos assume these numbers.

4. **Git hygiene.** The stack directory keeps `.env` out of version control if
   it is a repo at all; `.env.example` stays tracked. Never commit real
   credentials.

## Onboarding an app

This is the common case and usually the whole job. The app repo gets **no
compose file** — only environment variables.

1. **Pick a slug** for the app: the repo directory name, lowercased, `-` → `_`.

2. **Create its slice** against the running stack:
   ```bash
   docker exec -i postgres psql -U crane_admin -d postgres \
     -c 'CREATE DATABASE <slug>_main'

   docker exec -i s3 mc alias set local http://localhost:9000 minioadmin minioadmin
   docker exec -i s3 mc mb --ignore-existing local/<slug>

   docker exec -i redpanda rpk topic create <slug>.events   # if the app doesn't
   ```
   Create only what the app actually uses. If it needs roles, a DBOS system
   database or a cache database, hand off to the `pg-role-provisioning` skill
   for the SQL instead of inventing it here.

3. **Write the app's `.env`** with the endpoint block from `template/README.md`,
   substituting the slug. `OTEL_SERVICE_NAME` is required per app — every app
   reports into the same Grafana and that name is what keeps their traces
   apart. Use the 4318/`http/protobuf` pair for Pydantic Logfire and the DBOS
   Python SDK, which have no gRPC exporter.

4. **Point the app's README** at the shared stack — "start `~/Developer/docker`
   once" — rather than documenting per-repo containers.

## Retiring a per-repo stack

A repo carrying its own `docker/docker-compose.yml` of the same services is
redundant now. Migrating it: create the app's database/bucket/topics in the
shared stack, repoint the app's `.env` at the fixed ports above, then
`docker-compose down -v` in the old directory and delete it. Dump and restore
any data the user still wants first — ask before destroying volumes.

## Notes

- **`down -v` is machine-wide.** In the shared stack it deletes every repo's
  databases and buckets. Never run it to fix one app; confirm with the user
  before running it at all.
- **Containerized apps join the network, not the ports.** The compose project
  is named after the stack directory, so its network is `<dir>_default`
  (`docker_default` for `~/Developer/docker`). An app's own compose file
  declares that as `external: true` and talks to `postgres:5432`, `s3:9000`,
  `redpanda:9092`, `mailpit:1025`, `grafana:4317`. Redpanda's
  `--advertise-kafka-addr` serves host and container clients both.
  - Renaming or moving the stack directory renames the network and the volumes
    with it — the volumes are `<dir>_pgdata` and friends, so a move loses the
    data unless it is migrated. Leave the directory where it is.
- **Silo, not MinIO or LocalStack.** MinIO's public images are gone
  (`minio/minio` and `minio/mc` 404 on Docker Hub; quay.io requires auth) and
  LocalStack's current images are licence-gated (exit 55 without
  `LOCALSTACK_AUTH_TOKEN`) with in-memory-only community S3. `pgsty/silo` is
  the maintained MinIO fork: same S3 API, same `MINIO_*` env vars, same on-disk
  format, free under AGPLv3, keeps the console, ships `mc`. The compose file is
  kept comment-light on purpose, so this note is the only thing standing
  between the next person and reintroducing MinIO — keep it here.
- **Silo stays pinned** to a dated release. Object-storage tags have moved
  twice already; `:latest` is the same bet a third time. Use the plain tag, not
  `-distroless` (no `mc`, no `sh`).
- **otel-lgtm, not the Aspire dashboard.** The Aspire dashboard is lighter but
  only *displays* telemetry: a bounded in-memory buffer, no query language, no
  dashboards, nothing kept across a restart. `grafana/otel-lgtm` is one
  container carrying Grafana, Loki, Tempo, Prometheus and Pyroscope with the
  datasources pre-wired, persists to a volume, and answers
  PromQL/LogQL/TraceQL. The single `/data` mount covers all five backends.
- **No healthchecks, by design.** `depends_on: service_healthy` only works
  inside one compose project, and apps are no longer in this one. An app that
  needs to wait should retry its own connection on startup.
- The `fastapi-dbos-service` skill scaffolds its own compose project with the
  app services *and* a copy of these backing services. On a machine running
  this shared stack, strip the backing services out of what it generates and
  point the three app services at the shared endpoints — don't run two Postgres
  containers.
