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

- The image is **pinned to a dated release**, not `:latest` - object-storage
  tags have already moved under this template twice. Use the plain tag, not
  `-distroless`: that variant has no `mc`/`sh`, which the healthcheck
  (`mc ready local`) and the bucket one-shot need.
- `.env`'s `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are also Silo's root
  credentials (passed in as `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`). Silo
  enforces key >= 3 and secret >= 8 characters and won't start otherwise.
- Blobs **persist** on the `silodata` volume; `down -v` is what clears them.
- Browse via the web console on :9001, or `mc` inside the container.

## Databases

Two SEPARATE Postgres databases (same server, different databases), named the
way the `pg-role-provisioning` skill provisions them - `<app>`, `<app>_cache`,
`<app>_dbos`, of which this stack uses two:
- **Application DB** (`APP_DATABASE_URL`, `orders_api`) - our read model.
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
prerequisite (`backing/init-db.sql` locally; the `pg-role-provisioning` skill
for real environments), not an app responsibility. Same for the S3 bucket: the
one-shot `createbuckets` compose service creates it with `mc` (reusing the Silo
image), never the app at startup.

## Compose, config & networking

- **One compose file, one project**: `docker-compose.yml` holds the three app
  services AND the backing services (Postgres, Silo, Redpanda + Console,
  Mailpit, Aspire). No external network, no second compose file. Backing
  services get `restart: unless-stopped`; app services get neither that nor a
  `container_name` (fail-fast visibility, and `--scale worker=3` must work).
- All env comes from `.env` (gitignored; copy `.env.example`). Compose
  interpolates credentials from it with `${VAR:?...}` (fails loudly if unset);
  secrets are never hardcoded in the compose file.
- **Percent-encode passwords used in URLs.** `POSTGRES_PASSWORD` is the raw
  value Postgres wants; `POSTGRES_PASSWORD_URLENC` is the same password encoded
  for the `postgresql://` URLs. A bare `@` in a password silently breaks URL
  parsing. Keep them in sync.
- **Host vs in-network addressing differ.** Containers use service names
  (`postgres`, `redpanda`, ...); host runs (`run-local.sh`) use published ports.
  Redpanda is asymmetric: `redpanda:9092` in-network, `localhost:19092` on the
  host (internal vs external advertised listener).
- The stack claims standard host ports, so it collides with any other stack on
  them. The fix is a `docker-compose.override.yml` using `!override` on `ports`
  (plain lists get appended, not replaced) - see README.

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
cp .env.example .env            # first time
docker compose up -d --build    # everything: backing services + the three apps
./migrate.sh                    # app-DB schema (dbmate, after the DBs exist)
# or: ./run-local.sh infra      # backing only, then run one app on the host:
#     ./run-local.sh {api|worker|consumer}
```

`backing/init-db.sql` runs only on a fresh `pgdata` volume; `docker compose down
-v` is the reset. If `docker compose` isn't a plugin on this machine, use the
standalone `docker-compose` (run-local.sh detects both).

Python 3.12 (matches the container); PEP 604 `X | None` syntax is used.

## Namespace knobs (when templating this)

Change these together to re-theme the demo: the compose project `name:`, DB
names (`orders_api`, `orders_api_dbos`), the `crane` schema +
search_path (in `.env`, `backing/init-db.sql`), the bucket name (in `constants.py` AND the
`createbuckets` entrypoint in `docker-compose.yml`), OTel service names
(`order-api`/`order-worker`/`order-consumer`), the Kafka topic (`order-events`),
consumer group (`order-events-consumer`), DBOS queue (`orders_queue`) and the
app name (`APP_NAME`) in `constants.py`, and the S3 bucket (`orders-bucket`).

Renaming the app database means renaming `<app>_dbos` with it - the two are a
set. Note `<app>_dbos` is shorter than the system-database name DBOS derives on
its own, which is why `DBOS_DATABASE_URL` is always set explicitly rather than
left to a default.
