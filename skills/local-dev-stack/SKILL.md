---
name: local-dev-stack
description: Scaffold this repo's own local development stack as a docker-compose project — Postgres 17, Silo (S3-compatible object storage, the maintained MinIO fork), Redpanda + Console (Kafka), Mailpit (SMTP + web UI), and the Aspire dashboard (OTLP traces/logs/metrics) — with every host port and container name parameterized through .env so each repo's stack runs independently and side by side. Use whenever the user starts a new project or repo and wants local backing services, says "set up docker compose", "add the dev stack", "I need Postgres and Kafka locally", "spin up the local containers", "add S3/MinIO locally", "add a local SMTP server", "scaffold docker for this repo", or asks to add one of those services to an existing docker-compose.yml. Also use to re-point an existing stack onto a free port lane when two repos collide. Do NOT use for production/deployment compose files or for Dockerfiles that build the app itself.
---

# Local dev stack scaffold

Drops a self-contained `docker/` directory into the current repo. The stack is
**per repo** — never a shared machine-wide stack, never a shared compose file
between projects.

Files in `template/`: `docker-compose.yml`, `.env.example`, `README.md`. They
contain `${APP_NAME}` placeholders plus real `${PORT}` variables; see
Substitution below for which to replace and which to leave alone.

## What the stack contains

| Service | Purpose | Default host ports |
|---|---|---|
| `postgres` | Postgres 17-alpine, persisted | 5432 |
| `silo` + `silo-setup` | S3-compatible storage + one-shot bucket creator | 9000 API, 9001 console |
| `redpanda` + `redpanda-console` | Kafka-compatible broker + web UI | 19092, 8080 |
| `mailpit` | SMTP sink with web UI | 1025 SMTP, 8025 UI |
| `aspire-dashboard` | OTLP collector + trace/log/metric UI | 18888 UI, 18889 OTLP |

Postgres, Silo and Redpanda have healthchecks, so app services added later can
use `depends_on: { condition: service_healthy }`.

## Steps

1. **Confirm the repo root.** Everything lands in `<repo>/docker/`. If
   `docker/docker-compose.yml` already exists, read it first and merge rather
   than overwrite — report what you are changing before you change it.

2. **Pick which services to include.** Ask the user, offering all five as the
   default. Delete the blocks they don't want, along with the matching volume,
   `.env` variables, and README rows. Don't leave commented-out services behind.
   - `silo-setup` goes only where `silo` goes.
   - `redpanda-console` goes only where `redpanda` goes.

3. **Pick `APP_NAME`.** Default to the repo directory name, lowercased, with
   `-` → `_` (compose container names and project names dislike spaces and
   dots). Confirm it with the user if the directory name is generic (`app`,
   `src`, `poc`).

4. **Pick a port lane.** Run `docker ps --format '{{.Names}}\t{{.Ports}}'` and
   check the defaults. If another stack already holds them, shift this repo to
   a free lane (`+100` per lane: Postgres 5532, S3 9100/9101, Mailpit
   8125/1125, Kafka 19192/8180, Aspire 18988/18989) and say which lane you
   chose. Lane assignment lives only in `.env` — the compose file never
   hard-codes a host port.

5. **Write the files** into `<repo>/docker/`: `docker-compose.yml`,
   `.env.example`, `README.md`, and a `.env` copied from `.env.example` with the
   chosen values filled in.

6. **Decide on Postgres init SQL.** The `./backing:/docker-entrypoint-initdb.d`
   mount runs `*.sql`/`*.sh` on a *fresh volume only*. If the repo has no init
   scripts, **delete that mount line** — a bind mount to a missing path makes
   Docker create an empty root-owned directory. If the project needs extra
   databases, schemas or roles (DBOS, a cache db, the four-tier role model), keep
   the mount, create `docker/backing/init-db.sql`, and reach for the
   `pg-role-provisioning` skill for its contents.

7. **Git hygiene.** Add `docker/.env` to the repo's `.gitignore` (create it if
   absent); `.env.example` stays tracked. Never commit real credentials.

8. **Verify.** `cd docker && docker-compose config -q` (catches unset variables
   and syntax), then `docker-compose up -d` and `docker-compose ps`. Expect
   `silo-setup` to show `exited (0)` — that is success. If the user would rather
   not start containers, stop after `config -q` and say so.

9. **Report** the endpoint table and the app-config block from `README.md`, with
   the real ports substituted.

## Substitution

Replace `${APP_NAME}` everywhere — including inside `.env.example` and
`README.md`. Keep every other `${...}` as a literal: they are compose
interpolations resolved from `.env` at runtime, and that indirection is the
point of the skill. In `README.md` the `${PORT}`/`${POSTGRES_USER}` references
are documentation, not interpolation, so substitute the real values there.

## Notes

- **Silo, not MinIO or LocalStack.** MinIO's public images are gone (`minio/minio`
  and `minio/mc` 404 on Docker Hub; quay.io requires auth) and LocalStack's
  current images are licence-gated (exit 55 without `LOCALSTACK_AUTH_TOKEN`)
  with in-memory-only community S3. `pgsty/silo` is the maintained MinIO fork:
  same S3 API, same `MINIO_*` env vars, same on-disk format, free under AGPLv3,
  keeps the console, ships `mc`. The compose file carries this rationale in
  comments — keep it, it is what stops the next person reintroducing MinIO.
- **Silo stays pinned** to a dated release. Object-storage tags have moved twice
  already; `:latest` is the same bet a third time. Use the plain tag, not
  `-distroless` (no `mc`, no `sh`).
- **Volumes are namespaced** by `COMPOSE_PROJECT_NAME`, so two repos never share
  data even though both declare a `pgdata` volume.
- **Container-to-container addresses** are service names on the compose network
  (`postgres:5432`, `silo:9000`, `redpanda:9092`); the `.env` host ports apply
  only to processes outside Docker. Redpanda's `--advertise-kafka-addr` carries
  both.
- **Adding the app itself** to this compose file is fine (same project, one
  network). Give it `depends_on` with `service_healthy` on what it needs, and
  point it at the internal names, not `localhost`.
- The `fastapi-dbos-service` skill ships its own compose file covering this same
  stack plus three app services. If the user is scaffolding that service, use
  that skill instead of this one — don't produce two compose projects.
