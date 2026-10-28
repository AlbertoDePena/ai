# FastAPI + S3 + DBOS + Redpanda + OTel demo

A small order-processing service built from:

| Component | Role |
|---|---|
| **FastAPI** (`api`) | HTTP API + dashboard; accepts orders and enqueues them for processing |
| **Silo** | S3-compatible object storage where order blobs are written and updated; a maintained fork of open-source MinIO, same API as real S3 |
| **DBOS** (backed by Postgres) | Durable workflow queue - survives worker crashes and resumes from the last completed step instead of losing or reprocessing an order |
| **Redpanda** | Kafka-wire-compatible broker; an `order.processed` business event is published after each order finishes |
| **Consumer** (`consumer.py`) | DBOS Kafka consumer: `@DBOS.kafka_consumer` starts one durable workflow per `order.processed` event, which projects it into Postgres and notifies a downstream REST API |
| **Mailpit** | Local SMTP sink; the worker sends an order-confirmation email per order (swap for SES SMTP in prod) |
| **Aspire Dashboard** | Collects OTel traces/metrics/logs from all three services |

Three long-running services, all the same shape (uvicorn + FastAPI + lifespan + `/health`):
`api` (HTTP), `worker` (DBOS queue), and `consumer` (Kafka). The last two are the two worker
flavors, and both are DBOS apps running durable workflows - the only difference is what starts
the workflow: an explicit enqueue from the API, or a Kafka message.

## Architecture

```
FastAPI (api)                         Worker (worker.py)
  |  writes order -> S3                 |
  |  enqueues workflow -----> Postgres <-- DBOS dequeues, resumes on crash
  |  (DBOSClient)              (system DB)  |
                                             |-- runs process_order_step
                                             |-- updates status -> S3
                                             |-- sends confirmation email -> Mailpit (SMTP)
                                             |-- publishes order.processed -> Redpanda
                                                                                 |
                              Consumer (consumer.py) <-- consumes order-events ---'
                                 |  @DBOS.kafka_consumer starts a workflow per message
                                 |-- save_processed_order_step --> Postgres (application DB)
                                 |-- notify_downstream_step -----> external REST API
                                 '-- workflow state ------------> Postgres (the shared system DB)
                                             ^
         API reads this read model ---------'  (GET /processed-orders, async psycopg)

All three processes export OTel traces/metrics/logs -> Aspire Dashboard
```

## Run it

**One compose project holds everything** - the three app processes (`api`, `worker`,
`consumer`) and the backing services they need (Postgres, Silo for S3, Redpanda + Console,
Mailpit, Aspire Dashboard). They share the project's default network, so the app services
address the backing ones by service name (`postgres`, `silo:9000`, `redpanda:9092`, `mailpit`,
`aspire-dashboard`) with no external network to create first.

**Prerequisites:** Docker, and [dbmate](https://github.com/amacneil/dbmate#installation) on
your PATH (a standalone binary - `brew install dbmate`).

> **`docker compose` vs `docker-compose`.** Compose ships either as a `docker` CLI plugin
> (`docker compose ...`, used throughout this README) or as a standalone `docker-compose`
> binary. If `docker compose version` fails on your machine but `docker-compose version`
> works, substitute `docker-compose` in every command below. (`run-local.sh` detects which
> one you have.) To get the plugin form, symlink your installed plugin into the place the
> Docker CLI looks:
> `mkdir -p ~/.docker/cli-plugins && ln -s "$(brew --prefix)/lib/docker/cli-plugins/docker-compose" ~/.docker/cli-plugins/docker-compose`

**Steps:**

1. Create your env file:
   ```bash
   cp .env.example .env   # defaults work as-is; edit if needed
   ```
2. Start everything:
   ```bash
   docker compose up -d --build
   ```
   On the very first start, Postgres runs `backing/init-db.sql`, which creates both
   databases - `orders_api_main` (the application DB) and `orders_api_dbos` (the DBOS system DB,
   shared by the worker and the consumer) - plus the `crane` schema and its `search_path`. That
   script is a minimal local stand-in for provisioning; real environments use the
   `pg-role-provisioning` skill. Either way the services **fail if their database is
   missing** - provisioning is a prerequisite, not an app job.
3. Apply the application-DB schema with dbmate (DBOS migrates its own system DB itself):
   ```bash
   ./migrate.sh          # runs `dbmate up` against orders_api_main (see "Migrations" below)
   ```

> **If a cold `up` reports `dependency failed to start: container ... is unhealthy`,** run
> `docker compose up -d` once more. Some Compose builds misread a dependency's health while
> its container is still being created; the second run converges. (You can confirm Postgres
> itself is fine with `docker compose ps` - it reports `healthy`.)

> **Credentials come from `.env`.** They aren't hardcoded in `docker-compose.yml` - compose
> interpolates them from `.env`, which it loads automatically (no flag needed). Only the
> secrets come from there; the in-network hostnames (`postgres`, `redpanda`, ...) stay literal
> in the compose file, since they differ from `.env`'s host-side values (`localhost`, `19092`,
> ...). If `.env` is missing or incomplete, compose stops with `required variable
> POSTGRES_PASSWORD is missing a value: set it in .env` rather than starting with blank
> credentials. `.env` is gitignored, so it never lands in version control.

> **Passwords in URLs must be percent-encoded.** The database URLs are URLs, so a password
> containing `@ : / ? #` breaks parsing - a bare `@` ends the userinfo early and you get a
> confusing "could not translate host name" error. `.env` keeps the raw password in
> `POSTGRES_PASSWORD` (what Postgres itself wants) and the encoded copy in
> `POSTGRES_PASSWORD_URLENC` (what the URLs use). Keep the two in sync; `.env.example` has the
> encoding table.

- **API**: http://localhost:8000/dashboard (health at http://localhost:8000/health)
- **Worker health**: http://localhost:8001/health
- **Consumer health**: http://localhost:8002/health
- **Aspire Dashboard** (traces/metrics/logs): http://localhost:18888
- **Silo console** (browse the bucket): http://localhost:9001 - sign in with the
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` from `.env`
- **Redpanda Console**: http://localhost:8080 (inspect the `order-events` topic to watch messages land)
- **Mailpit**: http://localhost:8025 (watch the confirmation emails the worker sends)

Submit an order from the dashboard. It goes `queued -> processing -> done` over ~8s, then the
`order.processed` event lands in Redpanda and the consumer's own DBOS workflow projects it into
`processed_orders` (visible at `GET /processed-orders`).
In the Aspire Dashboard's **Traces** tab you'll see the `POST /orders` request as one trace,
the worker's DBOS workflow as a **separate** trace, and the consumer's workflow as a third.

> **Note on trace continuity:** DBOS 1.14 does not carry OTel trace context across an
> enqueue. `EnqueueOptions` has no `otel_context` field, the enqueue path ignores any extra
> keys, and no `traceparent` is persisted with the workflow's Postgres row - so when the
> worker dequeues and runs the workflow, its span starts a fresh root rather than continuing
> the request's trace. Stitching the two into one trace would require DBOS-level support (or
> manually persisting a `traceparent` at enqueue time and re-establishing the context on the
> worker before the workflow runs).

### Running alongside another stack

Because the stack ships inside the project, it claims the standard host ports (5432, 9000,
9001, 8080, 1025, 8025, 18888, 18889, 8000-8002). If you already run another stack on them -
a shared one, or a second project scaffolded from this template - you'll get
`Bind for 0.0.0.0:5432 failed: port is already allocated`. Two ways out:

- **Stop the other stack**, then `docker compose up -d` here.
- **Move this project's ports** with a `docker-compose.override.yml` next to
  `docker-compose.yml`. Compose merges it automatically, so no flags and no edits to the
  checked-in file (add it to `.gitignore` if the offsets are personal to your machine):

  ```yaml
  # docker-compose.override.yml
  services:
    postgres:
      ports: !override ["15432:5432"]
    silo:
      ports: !override ["19000:9000", "19001:9001"]
    api:
      ports: !override ["18000:8000"]
  ```

  **`!override` is required.** Without it compose *appends* to the port list rather than
  replacing it, so the original binding stays and the conflict remains. Remember to update the
  host-side URLs in `.env` (`APP_DATABASE_URL`, `KAFKA_BOOTSTRAP_SERVERS`, ...) to match, since
  `run-local.sh` and `migrate.sh` use them.

Container names are left to Compose (it prefixes them with the project name) precisely so two
projects don't collide on names as well as ports.

### Resetting, and "the init script already ran"

`backing/init-db.sql` is mounted into `/docker-entrypoint-initdb.d/` and Postgres runs it
**only on first init of an empty data volume**. Change it later, or point the stack at a volume
that already has data, and it will not run again - you'll see
`FATAL: database "orders_api_main" does not exist` from the app services. To start clean:

```bash
docker compose down -v      # -v drops the volumes, including pgdata
docker compose up -d --build
./migrate.sh
```

If you'd rather keep the existing data, apply the missing pieces by hand instead:

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d postgres \
  -c 'CREATE DATABASE orders_api_main' -c 'CREATE DATABASE orders_api_dbos'
```

(The DBOS system database is the forgiving one - DBOS creates its own tables in it if missing.
Only the application database is strictly provisioned out of band.)

## Run locally (no containers)

You can run `api`, `worker`, and `consumer` straight on the host while the backing services
stay in Docker - handy for a debugger, breakpoints, or `--reload`. The addressing differs from
the containers: you use the services' **host-published ports**, and Redpanda in particular
flips to `localhost:19092` (its external listener) rather than the in-network `redpanda:9092`.
Those values are what `.env` holds, and `run-local.sh` sources it.

```bash
./run-local.sh infra     # backing services only (no api/worker/consumer)
./run-local.sh api       # terminal 1: API + dashboard on :8000
./run-local.sh worker    # terminal 2: DBOS queue worker (+ /health) on :8001
./run-local.sh consumer  # terminal 3: DBOS Kafka consumer (+ /health) on :8002
```

`infra` is just `docker compose up -d` for the backing service names, so the three app services
in the same compose file stay down and you run them yourself. `run-local.sh` creates the
`.venv` and installs requirements on first run, then execs the process. `DEV_MODE=true` in
`.env` authenticates you as a local dev user, so no Azure vars are needed.

`.env`'s `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are also Silo's root credentials - compose
passes them through as `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` - so they're stated once. Silo
enforces a minimum length (key >= 3, secret >= 8) and refuses to start otherwise.

> **Python version:** the code uses PEP 604 (`X | None`) syntax and targets the container's
> Python 3.12. It also runs on 3.9 (macOS system Python) because `kafka.py` defers annotation
> evaluation with `from __future__ import annotations`. For full parity with the container,
> create the venv with a 3.12 interpreter.

## Networking

**In containers**, everything is on the compose project's default network and uses
service-name DNS:

| Service | In container (compose network) | On the host (`.env`) |
|---|---|---|
| Postgres | `postgres:5432` | `localhost:5432` |
| S3 (Silo) | `silo:9000` | `localhost:9000` |
| Redpanda | `redpanda:9092` | `localhost:19092` |
| Aspire OTLP | `aspire-dashboard:18889` | `localhost:18889` |

Two databases live on the same Postgres host above - different databases, not different
servers: the application DB (`orders_api_main`) and the DBOS system DB (`orders_api_dbos`), which the
worker and the consumer share. The names follow the `pg-role-provisioning` convention
(`<app>_main`, `<app>_cache`, `<app>_dbos`); this stack has no cache, so it uses two of the three.
See "Why one DBOS system database" below.

Redpanda is the one that isn't symmetric. **In a container** it must be reached on-network at
`redpanda:9092` - it advertises its internal listener as `redpanda:9092`, resolvable only for
containers on the compose network. **On the host** you use `localhost:19092` - its external
listener is published on the host as `:19092` and advertises `localhost:19092`, which resolves
from the host but is unreachable from inside another container. Everything else is just the
service name vs. its host-published port.

## How it works

### Object storage (S3 via Silo)

`s3.py` centralizes the boto3/aioboto3 client config. Locally it points at **Silo** - an
S3-compatible object storage server, maintained by the [Pigsty](https://silo.pgsty.com/)
project as a community fork of the open-source MinIO server, which exists because MinIO ended
community distribution of its own images. Silo's stated rule is *"the product and its delivery
surfaces are renamed; the protocol and your data are not"*: the S3 API, the `MINIO_*`
environment variables, the `minio_*` metrics and `x-minio-*` headers, and the on-disk format
all stay as they were. In practice that means none of the app code knows the difference, and an
existing MinIO data directory can be used as-is.

**To move to prod S3**: unset `S3_ENDPOINT_URL` and the
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars (let the Fargate task's IAM role supply
credentials), and set `S3_FORCE_PATH_STYLE=false`. No code changes.

**Credentials.** `.env`'s AWS keys are also Silo's root credentials - compose feeds them in as
`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`, so there's one pair to change. Silo validates their
length at startup and exits with
`MINIO_ROOT_USER length should be at least 3, and MINIO_ROOT_PASSWORD length at least 8
characters` if they're too short - so `test`/`test` won't do.

**Browsing blobs.** Silo keeps MinIO's web console: http://localhost:9001, signing in with
those same credentials. The `mc` CLI also ships inside the image:

```bash
docker compose exec silo mc alias set s http://silo:9000 "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
docker compose exec silo mc ls --recursive s/orders-bucket
docker compose exec silo mc cat s/orders-bucket/orders/<id>.json
```

**The bucket** is created by the one-shot `createbuckets` service, which reuses the Silo image
(already pulled, and it contains `mc`) rather than fetching a separate CLI image. The app
services gate on it with `condition: service_completed_successfully`, and it in turn waits for
Silo's own healthcheck (`mc ready local`).

**Blobs persist.** Silo writes to a real filesystem, so the `silodata` volume keeps objects
across container restarts and `docker compose down` / `up` cycles - only `down -v` clears them.

> **The image is pinned to a dated release** (`pgsty/silo:RELEASE.2026-09-16T00-00-00Z`) rather
> than `:latest`. Object-storage tags have moved under us twice already - `minio/minio` and
> `minio/mc` were withdrawn from Docker Hub entirely, and `localstack/localstack:latest` now
> refuses to start without a license token - so this one is nailed down. Also use the plain
> tag, **not** `-distroless`: that variant drops the `mc` and `sh` that the healthcheck and the
> bucket one-shot rely on.

### Durable workflow queue (DBOS)

- **`api.py`** uses `DBOSClient(system_database_url=...)` to enqueue the
  `process_order_workflow` by name onto the `orders_queue` queue - this writes directly into
  Postgres. The client is constructed with just the system-database URL; it coordinates with
  the worker purely through that shared database and the queue name. The API process never
  launches DBOS itself or defines the workflow; it just needs the name.
- **`workflows.py`** defines the actual workflow (`@DBOS.workflow()`) and its step
  (`@DBOS.step()`). This is only imported by the worker.
- **`worker.py`** is a FastAPI app with the same shape as the API (uvicorn + lifespan +
  `/health`), so it builds, deploys, health-checks, and shuts down identically. Its lifespan
  constructs the queue by instantiating `Queue(QUEUE_NAME)` **before** `DBOS.launch()` (that's
  what registers it, and launch is what starts the background dequeue loop). DBOS's own
  background threads then dequeue and execute workflows while uvicorn keeps the process alive
  and serves the health endpoint. `consumer.py` (below) uses this same shape for a Kafka
  consumer loop instead - started in lifespan startup, stopped on shutdown.

The durability property: if the worker crashes mid-step, DBOS's Postgres-backed state means
the workflow resumes from its last completed step on restart, rather than the message becoming
invisible/lost or needing a manual DLQ/redrive policy. You get this just by using
`@DBOS.step()`.

Scale the worker independently by running more replicas of the `worker` service - DBOS
coordinates dequeuing across all of them via Postgres.

### Business events (Redpanda)

`kafka.py` publishes an `order.processed` event to the `order-events` topic after the DBOS
step finishes, using `confluent-kafka` (works unchanged against any Kafka-wire-compatible
broker). **To point at a different cluster**: change `KAFKA_BOOTSTRAP_SERVERS`. If the cluster
needs TLS/SASL, add the relevant `security.protocol`/`sasl.*` keys to the `Producer(...)`
config dict in `get_producer()`.

Delivery is synchronous: after `produce()` we `flush()` and **raise if any event is still
undelivered** when the timeout hits. That failure propagates out of the DBOS step, so DBOS
retries it - giving at-least-once delivery instead of silently dropping the event when the
broker is slow or down. Flushing per event is fine at this volume (one event per workflow);
for a high-throughput producer you'd `poll()` periodically and `flush()` only on shutdown.

### Confirmation email (SMTP / Mailpit)

`smtp.py` sends a plaintext order-confirmation email over SMTP. The worker calls it from
`send_confirmation_email_step`, a dedicated `@DBOS.step()` after `process_order_step`: because
DBOS records a step's success in Postgres, a workflow replay (crash + recovery) won't resend an
email that already went out, and a transient SMTP failure is retried rather than dropped.

Locally it points at the **Mailpit** container (SMTP `:1025`, web UI http://localhost:8025),
which captures mail instead of delivering it - no auth or TLS. **For prod**, point
`SMTP_HOST`/`SMTP_PORT` at Amazon SES's SMTP endpoint (or any relay), set
`SMTP_USERNAME`/`SMTP_PASSWORD` (SES SMTP credentials) and `SMTP_USE_TLS=true` - the code path
is identical, Mailpit and SES both just speak SMTP. (The module is named `smtp.py`, not
`email.py`, so it doesn't shadow the stdlib `email` package that `smtplib` relies on.)

### Kafka consumer as a DBOS workflow (`consumer.py`)

`consumer.py` is the other worker flavor: instead of a DBOS queue the API enqueues onto, it's
driven by the `order-events` topic. Structurally it is the same thing as `worker.py` - a DBOS
app with the usual uvicorn + lifespan + `/health` shape - because the consuming is a decorator,
not a loop:

```python
# consumer_workflows.py
@DBOS.kafka_consumer(consumer_config(KAFKA_CONSUMER_GROUP), [KAFKA_TOPIC], in_order=False)
@DBOS.workflow()
def process_order_event_workflow(msg: KafkaMessage) -> None:
    event = json.loads(msg.value)
    save_processed_order_step(event["order_id"], event["item"], event["quantity"])
    notify_downstream_step(event["order_id"], event["item"], event["quantity"])
```

`@DBOS.kafka_consumer` must be the **outer** decorator - what it enqueues is the registered
workflow underneath it - and the workflow takes exactly one `KafkaMessage`. DBOS owns the poll
thread (started by `DBOS.launch()`, stopped by `DBOS.destroy()`), so there's no hand-rolled
consume loop, stop event, or background thread in `consumer.py` anymore.

The workflow does the two things a consumer usually wants to do with an event, one step each:

- **`save_processed_order_step`** - upserts into `processed_orders` in the application DB via
  `appdb.py`. This is **a different database from either DBOS system DB**, so the application's
  own data and DBOS's internal workflow tables never share a schema.
- **`notify_downstream_step`** - POSTs the event to an external REST API via `restapi.py`.
  `retries_allowed=True` with exponential backoff (1s, 2s, 4s), because a network call is the
  classic transient failure. Unset `EXTERNAL_API_URL` (the default) and the step logs and
  returns, so the stack boots with no downstream service wired up.

Add steps for whatever else an event should trigger. Each step's completion is recorded in
Postgres, so a crash between two steps resumes at the second one instead of redoing the first -
the DB write isn't repeated just because the API call failed.

#### Delivery semantics: exactly-once processing, for free

The old version of this service disabled Kafka auto-commit and committed the offset by hand
after each DB write, with an idempotent upsert to make replays harmless. None of that is here
anymore, because DBOS gives a stronger property more cheaply.

DBOS derives each workflow's ID deterministically from the message's coordinates:

```
kafka-unique-id-<topic>-<partition>-<group.id>-<offset>
```

Enqueueing a workflow ID that already exists is an upsert, not a second workflow. So a
redelivered message - consumer rebalance, restart, at-least-once broker - enqueues an ID DBOS
has already seen and **does not re-run the handler**. That's exactly-once *processing* on top
of at-least-once *delivery*, with no offset bookkeeping in our code.

Two consequences worth knowing:

- **Don't disable auto-commit.** DBOS's loop never commits manually, so turning auto-commit off
  would mean offsets never advance and every restart re-reads the whole topic. Durability
  doesn't rest on the offset anymore: the poll loop writes the enqueue to Postgres before moving
  on. (`kafka.py`'s `consumer_config()` spells this out.)
- **The consumer group id is part of the dedup key.** Changing `KAFKA_CONSUMER_GROUP`
  re-processes the topic under fresh workflow IDs. That's the deliberate way to replay a
  topic - and the reason `save_processed_order_step` keeps its `ON CONFLICT DO NOTHING`.

A message that can never be handled (bad JSON, a permanent 400 downstream) fails its workflow
and is left in the system DB with status `ERROR` - an inspectable dead letter you can query or
replay with the DBOS CLI - while the consumer moves on instead of spinning on one offset.

`in_order=False` lets workflows for different messages run concurrently, which is what you want
for an idempotent projection. Set `KAFKA_IN_ORDER = True` in `consumer_workflows.py` and DBOS
gives the topic a dedicated queue with `concurrency=1`, processing strictly in offset order -
correct when later events overwrite earlier ones for the same key, slower otherwise. (It
doesn't work with regex topic selectors.) Either way, scale out by running more `consumer`
replicas: they share one Kafka consumer group, so Kafka splits the topic's partitions across
them.

#### Why one DBOS system database

The worker and the consumer are **one DBOS app running as two processes**: same `APP_NAME`, same
`application_version`, same `DBOS_DATABASE_URL` (`orders_api_dbos`). That is DBOS's normal
horizontal-scaling shape - several processes of one app sharing its system database, each
picking up whatever work is pending.

Sharing comes with one rule, and it is not optional:

> **Every process must import every workflow module.**

Two mechanisms hand a process work it did not start:

- **Startup recovery** selects pending workflows by `(executor_id, application_version)`.
  `executor_id` defaults to `"local"` in every process that doesn't set `DBOS__VMID`, so both
  services match the same rows.
- **The internal queue.** `@DBOS.kafka_consumer` doesn't run the workflow inline; it *enqueues*
  it onto DBOS's internal queue (or a per-topic queue when `in_order=True`), and every process
  polls the internal queue.

A process that dequeues or recovers a workflow it never registered fails it with *"... is not a
registered workflow function"*. So `worker.py` and `consumer.py` both import **both**
`workflows.py` and `consumer_workflows.py`. Cross-importing them is the requirement here, not
the hazard.

What stays exclusive is the **Kafka poller**, and that is why `consumer_workflows.py` does not
stack `@DBOS.kafka_consumer` on its workflow the way DBOS's docs show. That decorator registers
a poll thread in whichever process imports the module, so stacking it would make the worker a
second Kafka consumer merely for registering the workflow. `consumer.py` instead applies it at
startup - `DBOS.kafka_consumer(...)(process_order_event_workflow)`, the identical call the
decorator makes - so exactly one process polls the topic while both can run the workflows those
messages produce.

Only the queue-driven side is still asymmetric by registration: `worker.py` instantiates
`Queue(QUEUE_NAME)`, and a process only polls queues it registered itself, so `orders_queue`
work runs on the worker. The consumer can still *recover* such a workflow after a crash, which
is exactly why it registers the function.

#### Reading the read model from the API (sync vs async pools)

The API exposes that table at `GET /processed-orders` and `GET /processed-orders/{order_id}` -
a small CQRS-style split: `/orders` reads the source of truth (JSON in S3), `/processed-orders`
reads the Postgres projection the consumer builds. So `appdb.py` is used by two callers with
different concurrency models, and offers a pool for each:

- the **consumer** uses the **sync** `ConnectionPool` - its DBOS steps run on DBOS's own
  background threads, where blocking DB calls are fine;
- the **API** uses the **async** `AsyncConnectionPool` - its endpoints run on the asyncio event
  loop, where a blocking call would stall every concurrent request, so DB access must be
  awaited. psycopg 3 is async-native, so this is the same driver, not a new dependency.

Each process opens only the pool it uses (the API in its lifespan startup, the consumer lazily
on its step threads); a pool is never shared across the sync/async boundary. This is the pattern to copy
whenever an async endpoint needs the database - reach for the async pool, not `to_thread` over
the sync one.

### Database migrations (dbmate)

The application-DB schema is **not** created by the apps - it's applied out of band by
[dbmate](https://github.com/amacneil/dbmate), so schema changes are reviewed, versioned, and
run once rather than raced by three services on startup. Migrations live in `db/migrations/`
(plain SQL with `-- migrate:up` / `-- migrate:down`), and `./migrate.sh` wraps dbmate:

```bash
./migrate.sh              # apply pending migrations (dbmate up)
./migrate.sh status       # show applied/pending
./migrate.sh down         # roll back the latest
./migrate.sh new add_xyz  # scaffold db/migrations/<timestamp>_add_xyz.sql
```

`migrate.sh` sources `.env`, points dbmate at `APP_DATABASE_URL` (normalizing the scheme and
forcing `sslmode=disable` for local Postgres), and tracks applied migrations in a
`schema_migrations` table in `orders_api_main`. It targets **only** the application DB - DBOS still
migrates its own system DB internally on `DBOS.launch()`. Run it after the databases are
provisioned and before starting the services.

### Shutdown & lifecycle

All three processes shut down cleanly on `SIGTERM`/`SIGINT` (what `docker stop`, ECS, and K8s
send):

- **`api`** - uvicorn catches the signal and runs the FastAPI `lifespan` shutdown, which calls
  `dbos_client.destroy()`.
- **`worker`** - same mechanism: uvicorn runs its `lifespan` shutdown, which drains in-flight
  workflows with `DBOS.destroy(workflow_completion_timeout_sec=12)` (stops dequeuing new work,
  waits for active workflows to finish and persist, then closes the DB) and flushes the Kafka
  producer (`close_producer()`). Letting uvicorn own the signals is why the worker no longer
  needs the hand-rolled `signal`/`threading` handling it used to carry - DBOS doesn't install
  signal handlers when embedded, but uvicorn does.
- **`consumer`** - same mechanism as the worker now that it's a DBOS app: `DBOS.destroy(...)`
  stops the Kafka poller first (no new messages are picked up), drains in-flight workflows, then
  closes the system DB. Its `lifespan` then releases the httpx client and the app-DB pool.

`docker-compose.yml` sets `stop_grace_period: 20s` on all three services so this cleanup isn't
cut off by Docker's default 10s SIGTERM→SIGKILL window. Even on a hard kill, no work is lost:
DBOS's Postgres-backed state resumes any in-flight workflow from its last completed step on
restart.

### Build note: `setuptools` pin

`requirements.txt` pins `setuptools<81`. The `python:3.12-slim` base image ships without
`setuptools`, and `opentelemetry-instrumentation` still imports `pkg_resources`, which
`setuptools` provides - but only through version 80. setuptools 81 removed the bundled
`pkg_resources` module, so an unpinned install crashes the containers at import time with
`ModuleNotFoundError: No module named 'pkg_resources'`.

## Azure AD auth

Flip `DEV_MODE=false` on the `api` service in `docker-compose.yml` and provide
`AZURE_TENANT_ID`/`AZURE_CLIENT_ID` (add them to `.env`, same as the other secrets). With
`DEV_MODE=true` (the default), requests are authenticated as a local dev user.

## Moving to Fargate / prod

| Env var | Local (compose + `.env`) | Prod |
|---|---|---|
| `S3_ENDPOINT_URL` | `http://silo:9000` | unset (real AWS) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `minioadmin` / `minioadmin` (also Silo's root creds) | unset (use IAM role) |
| `S3_FORCE_PATH_STYLE` | `true` | `false` |
| `DBOS_DATABASE_URL` (worker + consumer + api) | `postgres:5432/orders_api_dbos` | your RDS/Aurora Postgres instance - the **same** database for all three |
| `APP_DATABASE_URL` (consumer + api) | `postgres:5432/orders_api_main` | your RDS/Aurora Postgres instance |
| `KAFKA_BOOTSTRAP_SERVERS` | `redpanda:9092` | your real Redpanda cluster's brokers |
| `SMTP_HOST` / `SMTP_PORT` (worker) | `mailpit` / `1025` | SES SMTP endpoint (e.g. `email-smtp.us-east-1.amazonaws.com` / `587`) |
| `SMTP_USERNAME` / `SMTP_PASSWORD` / `SMTP_USE_TLS` (worker) | unset / unset / `false` | SES SMTP credentials / `true` |
| `EXTERNAL_API_URL` / `EXTERNAL_API_TOKEN` (consumer) | unset (step skipped) | your downstream REST API + its token |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://aspire-dashboard:18889` | your ADOT sidecar or collector |

Each of `api`, `worker`, and `consumer` maps to its own ECS task definition/service.
