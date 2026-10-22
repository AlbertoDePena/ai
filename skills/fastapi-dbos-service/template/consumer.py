"""
Kafka consumer service.

Same web-service shape as api.py / worker.py (uvicorn + FastAPI + lifespan +
/health), so it builds, deploys, health-checks, and shuts down identically.

It is also, now, a DBOS app - structurally the same as worker.py. The only
difference between the two services is what starts their workflows: worker.py
dequeues from a DBOS queue the API enqueues onto; this one is driven by the
@DBOS.kafka_consumer decorator in consumer_workflows.py, which polls the topic
and starts a workflow per message. DBOS owns the poll thread, the offsets, and
the dedup, so there's no hand-rolled consume loop or stop event here anymore.

Each message's workflow writes to the application Postgres database and/or
calls an external REST API - see consumer_workflows.py.

It shares the worker's DBOS system database (orders_api_dbos) and the worker's
APP_NAME: the two processes are ONE DBOS app, which is how DBOS scales a single
app horizontally. What that costs is a registration rule, and it is not
optional:

  Every process must import every workflow module.

DBOS recovers pending workflows by (executor_id, application_version), and
executor_id defaults to "local" in both processes, so either one can pick up a
workflow the other started. Kafka-driven workflows are also enqueued onto DBOS's
*internal* queue, which every process polls. A process that dequeues or recovers
a workflow it never registered fails it with "not a registered workflow
function" - so both services import both workflows.py and consumer_workflows.py,
and only the Kafka poller (below) is exclusive to this process.
"""

import os
from contextlib import asynccontextmanager

from dbos import DBOS, DBOSConfig
from fastapi import FastAPI
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

import otel_setup

# Configure OTel before anything emits spans/logs, and before DBOS(config=...)
# below - DBOS attaches its workflow/step spans to whichever provider is
# already registered, so enable_otlp=True puts them in the same pipeline.
otel_setup.configure_otel()

# Register EVERY workflow this app has, in every process - see the module
# docstring. consumer_workflows for the Kafka-driven one this service polls for,
# workflows for the queue-driven one the worker normally runs: this process can
# still be handed either by recovery or the internal queue.
import consumer_workflows  # noqa: E402
import workflows  # noqa: F401,E402

import appdb  # noqa: E402
import restapi  # noqa: E402
from constants import APP_NAME, KAFKA_CONSUMER_GROUP, KAFKA_TOPIC  # noqa: E402
from kafka import consumer_config  # noqa: E402


@asynccontextmanager
async def lifespan(app: FastAPI):
    config: DBOSConfig = {
        "name": APP_NAME,
        "application_version": os.environ.get("APP_VERSION", "0.1.0"),
        # The SAME database and name as the worker: one DBOS app, two processes.
        # Both values must match the worker's or recovery stops working across
        # them - see the module docstring.
        "system_database_url": os.environ["DBOS_DATABASE_URL"],
        "enable_otlp": True,
    }

    DBOS(config=config)

    # Attach the Kafka poller to the already-registered workflow. This is what
    # `@DBOS.kafka_consumer(...)` stacked above `@DBOS.workflow()` would do; it
    # lives here instead of in consumer_workflows.py so that only THIS process
    # polls the topic. The worker imports the same workflow module and must not
    # start a second poller just by doing so.
    DBOS.kafka_consumer(
        consumer_config(KAFKA_CONSUMER_GROUP),
        [KAFKA_TOPIC],
        in_order=consumer_workflows.KAFKA_IN_ORDER,
    )(consumer_workflows.process_order_event_workflow)

    # launch() starts the background threads: the Kafka poll loop registered
    # just above, and the queue thread that runs the workflows it enqueues.
    # The app DB schema is applied out of band by dbmate (./migrate.sh); the
    # steps just write to the table.
    DBOS.launch()
    DBOS.logger.info("Consumer launched, consuming topic '%s'", KAFKA_TOPIC)

    yield

    # uvicorn runs this on SIGTERM/SIGINT. destroy() stops the Kafka poller
    # first (no new messages are picked up), then waits for in-flight workflows
    # to finish and persist before closing the system DB. Keep the timeout
    # comfortably under the container's stop_grace_period.
    DBOS.logger.info("Shutting down, draining in-flight workflows")
    DBOS.destroy(workflow_completion_timeout_sec=12)
    restapi.close_client()
    appdb.close_pool()


app = FastAPI(title="Order Consumer", lifespan=lifespan)

# Same instrumentation as the other services; /health excluded from tracing.
# HTTPX instrumentation gives the downstream REST call its own span inside the
# workflow's trace.
FastAPIInstrumentor.instrument_app(app, excluded_urls="health")
HTTPXClientInstrumentor().instrument()


@app.get("/health")
async def health():
    return {"status": "ok"}
