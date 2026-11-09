"""
Worker service.

Runs as a long-running web service with the same shape as the API (uvicorn +
FastAPI + lifespan + /health), so it builds, deploys, health-checks, and shuts
down identically. The real work happens off to the side: DBOS's background
threads dequeue and execute workflows from the Postgres-backed queue. FastAPI
just owns the lifecycle and exposes a health endpoint for liveness/readiness
probes - uvicorn, not a hand-rolled signal handler, drives startup/shutdown.

WHY A WEB SERVICE AND NOT A BARE `signal` + `threading.Event` RUNNER

A DBOS worker needs no HTTP port to do its job, so hosting one looks like dead
weight. It is not, for two reasons:

1. It is what lets the orchestrator replace a WEDGED task, not just a crashed
   one. ECS/Kubernetes restart a process that *exits*; a worker that is alive
   but no longer dequeuing is the failure a probe exists to catch, and a probe
   needs something to probe. Note this needs no load balancer: an ECS
   container `healthCheck` runs its command inside the task, and in `awsvpc`
   mode every container in the task shares the network namespace, so
   `localhost` resolves. No ALB, no target group, no listener - those are only
   for services that receive traffic, which a queue worker does not. Use the
   same urllib one-liner docker-compose.yml uses rather than `curl -f ...`;
   `python:3.12-slim` ships no curl.
2. All three services stay one shape: one Dockerfile pattern, one task
   definition skeleton, one probe config, one deploy pipeline. In a fleet that
   uniformity is worth more than the handful of dependencies it costs.

The cost of a bare runner is not the dependencies it saves, it is losing (1)
and (2), and owning signal handling and PID-1 behaviour yourself.

But a probe is only worth having if it checks something real: `/health`
returning a hardcoded 200 is a FALSE GREEN - it proves uvicorn answers, not
that DBOS is dequeuing. See the endpoint at the bottom of this file, which
asserts the system database is reachable. Pair it with a liveness *metric*
(the last time this process completed a workflow) for alerting; the probe
handles task replacement, the metric handles "the whole service is stuck".

A worker like this consumes from a durable source. Here that's a DBOS workflow
queue; a Kafka consumer loop would slot in the same way - started in lifespan
startup, stopped on shutdown.

Scale independently of the API by running more replicas; DBOS's Postgres-backed
queue coordinates work across all of them.

This process and consumer.py are ONE DBOS app: same APP_NAME, same system
database (orders_api_dbos). That means either can be handed a workflow the other
started - by startup recovery, which matches on (executor_id,
application_version) and defaults executor_id to "local" in both, or off DBOS's
internal queue, which every process polls and which is where Kafka-driven
workflows land. So this process registers EVERY workflow the app has, not just
the queue-driven one. Dequeuing a workflow whose function was never registered
fails it with "not a registered workflow function".
"""

import asyncio
import os
from contextlib import asynccontextmanager

from dbos import DBOS, DBOSConfig
from fastapi import FastAPI, Response
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

import otel_setup

# Register our own TracerProvider/MeterProvider/LoggerProvider *before*
# DBOS(config=...) in the lifespan below. DBOS emits its workflow/step spans
# onto whichever global tracer provider is already registered, so with
# enable_otlp=True they join the same OTLP pipeline as everything else.
otel_setup.configure_otel()

# Importing these registers the @DBOS.workflow()/@DBOS.step() functions before
# DBOS.launch() is called. BOTH modules, in every process - see the docstring.
# consumer_workflows carries no Kafka poller of its own (consumer.py attaches
# that), so importing it here registers the workflow without turning this
# service into a second Kafka consumer.
# (E402 on these four: they deliberately follow configure_otel() above, the same
# way consumer.py orders its imports.)
import consumer_workflows  # noqa: F401,E402
import dbos_metrics  # noqa: E402
import workflows  # noqa: F401,E402
from constants import APP_NAME, QUEUE_NAME  # noqa: E402
from kafka import close_producer  # noqa: E402


@asynccontextmanager
async def lifespan(app: FastAPI):
    config: DBOSConfig = {
        "name": APP_NAME,
        # Bumped to 0.2.0 for the DBOS 3.x upgrade. 3.x changed the storage
        # format of workflow inputs/outputs: it can read rows written by 2.x,
        # but 2.x cannot read rows written by 3.x. Changing the version keeps
        # any in-flight 2.x workflows from being handed to a 3.x executor (and
        # vice versa) while both are briefly running. Bump it again on the next
        # such upgrade.
        "application_version": os.environ.get("APP_VERSION", "0.2.0"),
        # Shared with consumer.py - one app, one system database.
        "system_database_url": os.environ["DBOS_DATABASE_URL"],
        "enable_otlp": True,
    }

    DBOS(config=config)

    DBOS.launch()

    # Queues live in the system database in DBOS 3.x, so they are registered
    # AFTER launch - the reverse of the 2.x `Queue(name)` constructor, which was
    # removed in 3.0. A workflow enqueued onto a name nobody registered simply
    # stays ENQUEUED, so the API's QUEUE_NAME and this must match exactly.
    # Use the _async variant: the synchronous DBOS.register_queue raises
    # RuntimeError when called from a running event loop, which a FastAPI
    # lifespan always is.
    await DBOS.register_queue_async(QUEUE_NAME)

    # Schedules also live in the system database, so this is post-launch too.
    # Applied here and nowhere else - like the consumer's Kafka poller, one
    # owner - though the workflow it enqueues may run on any replica.
    dbos_metrics.apply_schedule()

    DBOS.logger.info("Worker launched, listening on queue '%s'", QUEUE_NAME)

    yield

    # uvicorn runs this on SIGTERM/SIGINT. Let in-flight workflows finish and
    # persist their results before the system DB is torn down: destroy() first
    # stops dequeuing new work, then waits up to this timeout for active
    # workflows to drain, then closes the DB and background threads. Without
    # the drain, a workflow completing mid-shutdown dies with "System database
    # accessed before DBOS was launched" and gets re-run on the next start.
    # Keep the timeout comfortably under the container's stop_grace_period.
    DBOS.logger.info("Shutting down, draining in-flight workflows")
    DBOS.destroy(workflow_completion_timeout_sec=12)
    # Final flush of buffered Kafka events. Each publish already flushes
    # synchronously, so by now this is belt-and-suspenders.
    close_producer()


app = FastAPI(title="Order Worker", lifespan=lifespan)

# Same instrumentation as the API; /health is excluded so probe traffic
# doesn't create spans.
FastAPIInstrumentor.instrument_app(app, excluded_urls="health")


HEALTH_TIMEOUT_SEC = 3.0


@app.get("/health")
async def health(response: Response):
    """Assert something real, not just that uvicorn answers.

    Reading the queue row back proves two things a static `{"status": "ok"}`
    cannot: this process can still reach the system database, and the queue it
    takes work from is registered. A worker that has lost its database is
    exactly the alive-but-wedged task the orchestrator should replace, and
    without this it would keep reporting healthy forever.

    The _async variant runs the query on a thread, so a slow or hung database
    can't block the event loop - and the timeout bounds how long the probe
    waits, since the system DB's own query timeout is far longer than any
    sensible health-check interval.

    What it deliberately does NOT prove is that DBOS's dequeue loop is still
    making progress. No public API exposes that; cover it with an alert on a
    liveness metric (time since this process last completed a workflow)
    instead. Probe handles task replacement, metric handles a stuck fleet.
    """
    try:
        queue = await asyncio.wait_for(
            DBOS.retrieve_queue_async(QUEUE_NAME), timeout=HEALTH_TIMEOUT_SEC
        )
    except Exception as exc:  # includes asyncio.TimeoutError
        DBOS.logger.warning("Health check failed: %s", exc)
        response.status_code = 503
        return {"status": "unhealthy", "reason": "system database unreachable"}

    if queue is None:
        response.status_code = 503
        return {"status": "unhealthy", "reason": f"queue '{QUEUE_NAME}' not registered"}

    return {"status": "ok", "queue": QUEUE_NAME}
