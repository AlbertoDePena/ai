# CLAUDE.md

Conventions for this project (a FastAPI + DBOS + Kafka + Postgres + S3 + OTel
order-processing template). Follow these when editing or extending it.

## Services

Three long-running services, each a uvicorn + FastAPI app with a `lifespan` and
a `/health` endpoint, so they build, deploy, health-check, and shut down
identically:

- `api.py` (`api`, :8000) - HTTP API + dashboard; enqueues work, reads models.
- `worker.py` (`worker`, :8001) - DBOS queue worker; runs the durable workflow.
- `consumer.py` (`consumer`, :8002) - DBOS Kafka consumer; one workflow per event.

`worker` and `consumer` are the two "worker flavors". **Both are DBOS apps running
durable workflows**; only the trigger differs - the worker dequeues what the API
enqueued, the consumer is driven by `@DBOS.kafka_consumer`. New long-running
services should copy this shape (lifespan owns startup/shutdown; `/health` for
probes), and reach for a DBOS workflow rather than a hand-rolled poll loop.

Workflow modules are per-service and must not be cross-imported: `workflows.py`
only by `worker.py`, `consumer_workflows.py` only by `consumer.py` (see
"Databases" for why).

## Module naming: name for the tech, not the role

`s3.py`, `kafka.py`, `smtp.py`, `appdb.py`, `restapi.py`, `azure_auth.py` - each
wraps the concrete dependency it talks to. Avoid role names like
`storage.py`/`events.py`. Don't shadow stdlib/3rd-party modules: it's `smtp.py`
(not `email.py`), `restapi.py` (not `http.py`), and the local `kafka.py` coexists
with `confluent_kafka`.

## Async rule

Never block the asyncio event loop uvicorn runs on.
- API endpoints are `async` and use async I/O: `aioboto3`, `enqueue_async`, and
  `appdb`'s **async** pool (`AsyncConnectionPool`).
- Blocking work runs on threads, not the loop: DBOS runs workflows and steps on
  its own background threads (both services), and owns the Kafka poll thread.
  Step code therefore uses `appdb`'s **sync** pool and `restapi`'s sync httpx
  client - correct there, since no event loop is running on those threads.
- `appdb.py` exposes both a sync and an async pool; a process opens only the one
  it needs, and they're never shared across the boundary. When an async
  endpoint needs the DB, reach for the async pool - not `to_thread` over sync.

## Object storage

**S3 via Silo** (`pgsty/silo`), a maintained community fork of the open-source
MinIO server. It keeps MinIO's S3 API, `MINIO_*` env vars, and on-disk format,
so the app talks plain S3 through `s3.py` and nothing is Silo-specific - moving
to real S3 is an env change (`S3_ENDPOINT_URL` unset,
`S3_FORCE_PATH_STYLE=false`, IAM role for creds).

- The image, its pinning and its volume belong to the **shared dev stack**, not
  to this project - see the local-dev-stack skill. In the shared stack the
  container and service are both named `s3`, which is why this project addresses
  it as `http://s3:9000` in containers and `http://localhost:9000` on the host.
- `.env`'s `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` must equal that stack's
  `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`. Silo enforces key >= 3 and secret
  >= 8 characters.
- Blobs **persist** on the shared stack's volume. `down -v` over there clears
  every repo's buckets, not just this one's.
- The bucket is created by `./setup-devstack.sh` (`mc mb --ignore-existing`
  inside the `s3` container), never by the app at startup.
- Browse via the web console on :9001, or `mc` inside the container.

## Databases

Two SEPARATE Postgres databases (same server, different databases), named the
way the `pg-role-provisioning` skill provisions them - `<app>_main`,
`<app>_cache`, `<app>_dbos`, of which this stack uses two:
- **Application DB** (`APP_DATABASE_URL`, `orders_api_main`) - our read model.
- **DBOS system DB** (`DBOS_DATABASE_URL`, `orders_api_dbos`) - SHARED by the
  worker and the consumer. DBOS owns it and migrates it itself on
  `DBOS.launch()`. Don't touch its schema.

**One system DB, one DBOS app, several processes.** The worker and the consumer
share `APP_NAME`, `application_version` and the system database, which is DBOS's
normal horizontal-scaling shape. The rule that makes it safe:

> **Every process imports every workflow module.**

Both startup recovery (which matches on `(executor_id, application_version)`,
and `executor_id` defaults to `"local"` everywhere) and DBOS's internal queue
(where `@DBOS.kafka_consumer` enqueues, and which every process polls) hand a
process work it did not start. Dequeuing or recovering an unregistered workflow
fails it with "not a registered workflow function" - so `worker.py` and
`consumer.py` import **both** `workflows.py` and `consumer_workflows.py`.

What stays per-process is the **Kafka poller**: `consumer_workflows.py`
deliberately does NOT stack `@DBOS.kafka_consumer` on its workflow (that would
start a poll thread in every importer, including the worker). `consumer.py`
applies it at startup instead. Same for `Queue(QUEUE_NAME)`, instantiated only
in `worker.py` - a process polls only the queues it registered itself.

A new DBOS service joins this same app and database: import every workflow
module in it too, and keep any poller/queue registration in that service's entry
point.

App schema is managed **out of band by dbmate**, never created by the apps:
`db/migrations/*.sql` + `./migrate.sh` (see README "Migrations"). Table names in
code and migrations are **unqualified**; the role's `search_path` (set by
provisioning) decides the schema, so nothing is tied to a schema name.

Services **fail fast** if their database is missing - provisioning is a
prerequisite (`backing/init-db.sql` via `./setup-devstack.sh` locally; the
`pg-role-provisioning` skill for real environments), not an app responsibility. Same for the S3 bucket:
`./setup-devstack.sh` creates it with `mc` inside the shared stack's `s3`
container, never the app at startup.

## Compose, config & networking

- **This project is the three app services only.** `docker-compose.yml` holds
  `api`, `worker` and `consumer`; the backing services (Postgres, Silo/S3,
  Redpanda + Console, Mailpit, otel-lgtm) are the machine's **shared** dev
  stack, a separate compose project started once and used by every repo. This
  project attaches to that stack's network as `external: true`
  (`${DEVSTACK_NETWORK:-docker_default}`, named after the stack's directory).
  App services get no `restart` policy and no `container_name` (fail-fast
  visibility, and `--scale worker=3` must work).
- **No `depends_on` on the backing services** - compose can only express that
  within one project. The app services fail fast on a missing dependency, which
  is the behaviour to want; start the shared stack first.
- **`./setup-devstack.sh` does what compose used to do implicitly**: the two
  databases + schema (`backing/init-db.sql`, now applied with `psql`, not
  mounted into `/docker-entrypoint-initdb.d/`), the S3 bucket, the Kafka topic.
  Every step is idempotent, so re-run it freely.
- **Credentials must match the shared stack's `.env`**, because this project
  connects to that stack rather than configuring it.
- All env comes from `.env` (gitignored; copy `.env.example`). Compose
  interpolates credentials from it with `${VAR:?...}` (fails loudly if unset);
  secrets are never hardcoded in the compose file.
- **Percent-encode passwords used in URLs.** `POSTGRES_PASSWORD` is the raw
  value Postgres wants; `POSTGRES_PASSWORD_URLENC` is the same password encoded
  for the `postgresql://` URLs. A bare `@` in a password silently breaks URL
  parsing. Keep them in sync.
- **Host vs in-network addressing differ.** Containers use the shared stack's
  service names (`postgres`, `s3`, `redpanda`, `mailpit`, `grafana`); host runs
  (`run-local.sh`) use its published ports. Redpanda is asymmetric:
  `redpanda:9092` in-network, `localhost:19092` on the host (internal vs
  external advertised listener).
- Only `8000-8002` are published from this project now, so it no longer collides
  with the backing ports. Two projects scaffolded from this template still
  collide with each other on 8000-8002; the fix is a
  `docker-compose.override.yml` using `!override` on `ports` (plain lists get
  appended, not replaced) - see README.

## Delivery semantics

- Kafka publish (worker): synchronous `flush()`, **raise if undelivered** so the
  DBOS step retries -> at-least-once.
- Kafka consume (consumer): DBOS names each workflow
  `kafka-unique-id-<topic>-<partition>-<group.id>-<offset>`, and enqueueing an
  existing ID is an upsert - so a redelivered message doesn't re-run the
  handler. At-least-once delivery, **exactly-once processing**, no offset
  bookkeeping of ours.
  - **Don't set `enable.auto.commit: False`** - DBOS never commits manually, so
    offsets would never advance and every restart would replay the topic.
  - `KAFKA_CONSUMER_GROUP` is part of the dedup key; changing it replays the
    topic under fresh IDs. That's why the upsert keeps `ON CONFLICT DO NOTHING`.
  - An unhandleable message fails its workflow and sits in the system DB with
    status `ERROR` - an inspectable dead letter, not a stuck offset.
- Outbound REST call (consumer): `@DBOS.step(retries_allowed=True, ...)` for
  transient failures, plus an `Idempotency-Key` header - DBOS makes our side
  exactly-once, only the downstream can make its own side exactly-once.

## Shutdown

uvicorn owns SIGTERM/SIGINT and runs each service's `lifespan` shutdown (no
hand-rolled signal handlers). Both DBOS services drain in-flight workflows with
`DBOS.destroy(workflow_completion_timeout_sec=...)` before closing - for the
consumer that also stops the Kafka poller first. Compose sets
`stop_grace_period: 20s`; keep the drain timeout comfortably under it.

## Local workflow

```bash
cp .env.example .env            # first time; match the shared stack's .env
./run-local.sh infra            # start the shared dev stack (no-op if already up)
./setup-devstack.sh             # databases + schema, bucket, topic (idempotent)
./migrate.sh                    # app-DB schema (dbmate, after the DBs exist)
docker compose up -d --build    # the three app services
# or run one on the host instead:
#     ./run-local.sh {api|worker|consumer}
```

`./setup-devstack.sh --check` reports what exists without changing anything. If
the shared stack is ever reset with `down -v`, re-run `setup-devstack.sh` and
`migrate.sh` - note that reset wipes EVERY repo's data, not just this one's. If
`docker compose` isn't a plugin on this machine, use the standalone
`docker-compose` (run-local.sh detects both).

Python 3.12 (matches the container); PEP 604 `X | None` syntax is used.

## Namespace knobs (when templating this)

Change these together to re-theme the demo: the compose project `name:`, DB
names (`orders_api_main`, `orders_api_dbos`), the `crane` schema +
search_path (in `.env`, `backing/init-db.sql`), the bucket name and Kafka topic
(in `constants.py` AND `setup-devstack.sh`), OTel service names
(`order-api`/`order-worker`/`order-consumer`), the Kafka topic (`order-events`),
consumer group (`order-events-consumer`), DBOS queue (`orders_queue`) and the
app name (`APP_NAME`) in `constants.py`, and the S3 bucket (`orders-bucket`).

Renaming the app database means renaming `<app>_dbos` with it - `<app>_main`
and `<app>_dbos` are a set derived from one `<app>` base. Note `<app>_dbos` is
shorter than the system-database name DBOS derives from `<app>_main` on its
own, which is why `DBOS_DATABASE_URL` is always set explicitly rather than left
to a default.
