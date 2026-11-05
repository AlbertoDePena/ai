---
name: fastapi-dbos-service
description: Scaffold a new Python service from an opinionated FastAPI + DBOS + Kafka + Postgres + S3 + OTel template. Produces three deployable services that share one shape (uvicorn + FastAPI + lifespan + /health) - an HTTP API, a DBOS durable-workflow queue worker, and a DBOS Kafka consumer (@DBOS.kafka_consumer) that runs one durable workflow per event to project it into Postgres and/or call an external REST API - plus a docker-compose project for the three services that attaches to the machine's SHARED local dev stack (Postgres, Silo for S3, Redpanda, Mailpit, otel-lgtm/Grafana) instead of running backing services of its own, dbmate migrations, OpenTelemetry wiring, and SMTP email. Use whenever the user wants to start a new async Python microservice or event-driven service, a DBOS workflow worker, a Kafka consumer-to-Postgres projector, or an order/job-processing backend, parameterized around their own namespace and domain entity. Trigger on requests like "scaffold a new FastAPI service", "new DBOS worker service", "set up a Kafka consumer that writes to Postgres", "spin up an event-driven python service with workers", or "create a service like the orders demo for <X>". Pairs with the pg-role-provisioning skill for the database/role setup. Do NOT use for a plain single-file FastAPI app with no workers/queue/events.
---

# FastAPI + DBOS service scaffold

This skill bundles a complete, working reference project under `template/` and
turns it into a new service by substituting a **domain entity** and a
**namespace**. The template is an order-processing demo; you re-theme it.

## What the template contains

Three long-running services, each a uvicorn + FastAPI app with a `lifespan` and
`/health`:

- `api.py` - HTTP API + dashboard; writes to S3, enqueues a DBOS workflow, reads a Postgres read model.
- `worker.py` - DBOS durable-workflow queue worker (processes, updates S3, sends email, publishes a Kafka event).
- `consumer.py` - DBOS Kafka consumer: `@DBOS.kafka_consumer` starts one durable
  workflow per `*.processed` event (`consumer_workflows.py`), with a step that
  projects it into Postgres and a step that POSTs it to an external REST API.

`worker` and `consumer` are two processes of **one** DBOS app; only the trigger
differs. They share one system database (`<app>_dbos`), which is DBOS's normal
horizontal-scaling shape - and that imposes one rule: **every process imports
every workflow module**, because both startup recovery (keyed on
`(executor_id, application_version)`, and `executor_id` defaults to `"local"`)
and DBOS's internal queue (where `@DBOS.kafka_consumer` enqueues, and which every
process polls) can hand a process work it did not start. Only the Kafka poller
and the queue registration stay per-process - see the Notes.

Plus a `docker-compose.yml` holding **only** those three app services. The
backing services (Postgres, Silo for S3, Redpanda + Console, Mailpit, otel-lgtm)
are the machine's **shared** local dev stack - one compose project, started once,
used by every repo - and this project attaches to its network as
`external: true`. See the `local-dev-stack` skill for the stack itself.

Then `setup-devstack.sh` (carves this project's slice out of the shared stack:
databases, schema, bucket, topic - all idempotent), `backing/init-db.sql` (the
SQL that script applies), `db/migrations/` with `migrate.sh` (dbmate),
`requirements.txt`, Dockerfiles, `run-local.sh` (`infra` starts the shared stack;
the three services run on the host), `.env.example`, and `README.md`.

**Read `template/CLAUDE.md` first** - it is the source of truth for the
conventions (service shape, "name modules for the tech", the async sync-pool vs
async-pool rule, two separate databases, dbmate-owned schema, fail-fast,
host-vs-in-network addressing, delivery semantics). Carry those conventions into
whatever you add; don't reinvent them.

## Parameters

Ask the user for these (offer the demo defaults):

| Parameter | Demo value | Drives |
|---|---|---|
| **entity** | `order` | the domain noun: identifiers, topic/queue/bucket/table names, OTel service names, the request model, routes |
| **namespace** | `crane` | the Postgres schema + role prefix (hand this to `pg-role-provisioning`); the role's `search_path` resolves unqualified table names |
| **app DB name** | `orders_api_main` | `APP_DATABASE_URL` database |
| **DBOS DB name** | `orders_api_dbos` | `DBOS_DATABASE_URL` database, shared by worker + consumer + api |

Database names follow the `pg-role-provisioning` convention - `<app>_main`,
`<app>_cache`, `<app>_dbos` - all three derived from the `<app>` base, so every
db name carries a suffix and nothing sits on the bare `<app>`. This stack has
no cache, so it uses two of the three. `<app>_dbos` is shorter than the name
DBOS derives from `<app>_main` on its own, which is why `DBOS_DATABASE_URL` is
always set explicitly rather than left to a default.

## Steps

1. **Copy** `template/` into the user's chosen project directory.

2. **Re-theme the entity.** Replace the order/orders/Order nouns with the
   user's entity across identifiers and strings. Touch points:
   - `constants.py` - `QUEUE_NAME`, `PROCESS_ORDER_WORKFLOW`, `KAFKA_TOPIC`
     (`<entity>-events`), `KAFKA_CONSUMER_GROUP`, `BUCKET_NAME`, `APP_NAME`.
   - `api.py` - `OrderIn` model, `/orders` + `/processed-orders` routes, `create_order`.
   - `workflows.py` - `process_order_*`, the event payload fields.
   - `kafka.py` - `publish_order_processed`, the `order.processed` event type.
   - `appdb.py` - table name (`processed_<entity>s`) and the save/read helpers.
   - `consumer_workflows.py` - `process_order_event_workflow` and its steps
     (`save_processed_order_step`, `notify_downstream_step`); the downstream path
     (`/orders`) in the POST.
   - `restapi.py` - nothing entity-specific, but check the base URL/auth shape
     matches the downstream service.
   - `db/migrations/*_create_processed_orders.sql` - table name.
   - `docker-compose.yml` - the project `name:`, the OTel `OTEL_SERVICE_NAME`s
     (`<entity>-api/-worker/-consumer`), and the DB names in the URLs.
   - `backing/init-db.sql` - the two DB names + the namespace schema.
   - `setup-devstack.sh` - `BUCKET_NAME` and `KAFKA_TOPIC` (keep them equal to
     `constants.BUCKET_NAME` and `constants.KAFKA_TOPIC`).
   - `README.md` - rename throughout.
   A careful global rename (`order`->`<entity>`, `Order`->`<Entity>`) is usually
   the fastest path; review the diff.

3. **Set namespace + DB names.** Update `.env.example` DB URLs (both), the
   compose project `name:` and OTel names, and `backing/init-db.sql` (schema
   name + `search_path` + both DB names) to the chosen namespace and DB names.
   Keep table references **unqualified** in code and migrations - the schema
   comes from the role's `search_path`.

   The database, bucket and topic names are what keep this project's data apart
   from every other project's in the shared stack, so they must be unique per
   project - the `<app>_main`/`<app>_dbos` convention handles that as long as
   each project picks its own `<app>` base.

   Also point `.env.example` at the shared stack: `DEVSTACK_DIR` (where its
   compose file lives, default `~/Developer/docker`) and `DEVSTACK_NETWORK` (its
   network, `<that directory>_default`). The Postgres and S3 credentials must
   **match that stack's own `.env`** - this project connects to it, it does not
   configure it.

   `.env.example` carries the password twice on purpose: `POSTGRES_PASSWORD`
   (raw, for the Postgres container) and `POSTGRES_PASSWORD_URLENC`
   (percent-encoded, for the `postgresql://` URLs). If the user's password has
   `@ : / ? #` in it, encode it - a bare `@` silently breaks URL parsing.

4. **Provision the databases.** Use the **pg-role-provisioning** skill with the
   same namespace to create the roles, the databases, the schema, and the
   `search_path`. That skill provisions `<app>_main`, `<app>_cache` and
   `<app>_dbos`; this stack uses `<app>_main` and `<app>_dbos` and leaves the
   cache database
   unused (pass `-k` to skip creating it). Point `DBOS_DATABASE_URL` at
   `<app>_dbos` explicitly - it is shorter than the name DBOS would derive on
   its own. (`backing/init-db.sql`, applied by `./setup-devstack.sh`, is only a
   minimal local stand-in for it.)

5. **Bring it up** (also in `README.md`):
   ```bash
   cp .env.example .env            # credentials must match the shared stack's .env
   ./run-local.sh infra            # start the shared dev stack (no-op if already up)
   ./setup-devstack.sh             # databases, schema, bucket, topic (idempotent)
   ./migrate.sh                    # dbmate: create the read-model table
   docker compose up -d --build    # api :8000, worker :8001, consumer :8002
   ```
   The shared stack must be up **before** `docker compose up`, or compose stops
   with `network docker_default declared as external, but could not be found` -
   that is the intended failure, not a bug to work around. `dbmate` must be on
   PATH (standalone binary). On a machine where Compose is only the standalone
   binary, it's `docker-compose` instead of `docker compose`.

## Notes

- Keep the DBOS system DB and the application DB separate, but keep it to **one
  system DB for the whole app**: every DBOS service shares `<app>_dbos`. DBOS
  migrates its own; dbmate owns the app schema. A new DBOS service joins that
  same database and app name - and must import every workflow module, or it will
  fail the work it dequeues with *"not a registered workflow function"*.
- Consume Kafka with `@DBOS.kafka_consumer` over a hand-rolled poll loop, but do
  **not** stack it on `@DBOS.workflow()` the way DBOS's docs show. The decorator
  registers a poll thread in whichever process imports the module, and here every
  process imports every workflow module - so the worker would become a second
  Kafka consumer. Define the workflow with `@DBOS.workflow()` alone and apply
  `DBOS.kafka_consumer(config, topics, in_order=...)(workflow_fn)` in the
  consumer's lifespan instead: the identical call, made in one process. The
  workflow still takes exactly one `KafkaMessage`, and the deterministic
  workflow ID
  (`kafka-unique-id-<topic>-<partition>-<group.id>-<offset>`) is what turns
  at-least-once delivery into exactly-once processing. Don't set
  `enable.auto.commit: False` - DBOS never commits manually, so offsets would
  never advance.
- Don't cross-import the workflow modules: `workflows.py` belongs to the worker,
  `consumer_workflows.py` to the consumer. Importing one into the other
  registers its workflows in the wrong process.
- Don't hardcode credentials in compose - interpolate from `.env` (the template
  already does this with `${VAR:?...}`). The Postgres and S3 credentials must
  equal the shared stack's, since this project connects to that stack rather
  than configuring it.
- **Don't put backing services in this compose file.** They are the shared dev
  stack's, and a second Postgres or Redpanda on the same machine is exactly what
  that stack exists to prevent. This project declares that stack's network as
  `external: true` and addresses `postgres`, `s3`, `redpanda`, `mailpit` and
  `grafana` by service name. App services take no restart policy (fail-fast must
  be visible) and no `container_name` (it breaks `--scale` and collides across
  projects).
- **No `depends_on` on the backing services** - compose can only express that
  within one project. Start the shared stack first; `external: true` makes
  compose refuse to start if it isn't up, which is the right failure.
- Only `8000-8002` are published here now, so this no longer fights the backing
  ports. Two projects scaffolded from this template still collide with each other
  there; the answer is a `docker-compose.override.yml` with
  `ports: !override [...]` - a plain list is appended, not replaced.
- **Object storage is Silo** (`pgsty/silo`), a maintained community fork of the
  open-source MinIO server, running in the shared stack as the service and
  container `s3`. It keeps MinIO's S3 API, `MINIO_*` env vars and on-disk format,
  so it's a drop-in: blobs persist on that stack's volume, the web console is on
  :9001, and `mc` ships inside the image (which is how `setup-devstack.sh`
  creates the bucket).
  - Don't reach for MinIO or LocalStack instead: `minio/minio` and `minio/mc`
    were withdrawn from Docker Hub (404), and `localstack/localstack:latest`
    exits with `License activation failed!` without a `LOCALSTACK_AUTH_TOKEN`
    (its last free line is 4.9, and its community S3 is in-memory only).
  - `.env`'s AWS keys are the shared stack's Silo root credentials. Silo enforces
    key >= 3 and secret >= 8 characters and refuses to start otherwise, so
    `test`/`test` is not a usable default.
- **Provisioning is a script now, not a compose side effect.** `setup-devstack.sh`
  creates the databases, schema, bucket and topic; nothing happens implicitly on
  a fresh volume, because the Postgres volume belongs to every repo. Keep every
  step idempotent so it can be re-run after a stack reset.
- **Never tell the user to `down -v` the shared stack** to fix this project - it
  deletes every repo's data. Drop this project's own databases and bucket and
  re-run `setup-devstack.sh` instead (README "Resetting").
- Drop any service the user doesn't need (e.g. no Kafka consumer, or no email),
  but preserve the lifespan + `/health` shape for the ones that remain. Dropping
  the consumer leaves the system database in place - it belongs to the app, not
  to that service.
- The consumer's two steps are the two things an event handler usually does:
  write to our Postgres, or call something else. Add, replace, or remove steps
  per the user's actual flow - one `@DBOS.step()` per side effect, so a crash
  between two of them doesn't redo the first. `EXTERNAL_API_URL` unset means the
  downstream step logs and returns, so the stack boots without it.
