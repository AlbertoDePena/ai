"""
Worker service.

Runs as a long-running web service with the same shape as the API (uvicorn +
FastAPI + lifespan + /health), so it builds, deploys, health-checks, and shuts
down identically. The real work happens off to the side: DBOS's background
threads dequeue and execute workflows from the Postgres-backed queue. FastAPI
just owns the lifecycle and exposes a health endpoint for liveness/readiness
probes - uvicorn, not a hand-rolled signal handler, drives startup/shutdown.

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

import os
from contextlib import asynccontextmanager

from dbos import DBOS, DBOSConfig, Queue
from fastapi import FastAPI
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
import workflows  # noqa: F401,E402
from constants import APP_NAME, QUEUE_NAME  # noqa: E402
from kafka import close_producer  # noqa: E402


@asynccontextmanager
async def lifespan(app: FastAPI):
    config: DBOSConfig = {
        "name": APP_NAME,
        "application_version": os.environ.get("APP_VERSION", "0.1.0"),
        # Shared with consumer.py - one app, one system database.
        "system_database_url": os.environ["DBOS_DATABASE_URL"],
        "enable_otlp": True,
    }

    DBOS(config=config)

    # Instantiating Queue registers it with DBOS. This must happen *before*
    # DBOS.launch() so the queue's background dequeue loop is started.
    Queue(QUEUE_NAME)

    DBOS.launch()
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


@app.get("/health")
async def health():
    return {"status": "ok"}
