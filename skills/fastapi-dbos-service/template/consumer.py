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

import asyncio
import os
from contextlib import asynccontextmanager

from dbos import DBOS, DBOSConfig
from fastapi import FastAPI, Response
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
        # Bumped to 0.2.0 for the DBOS 3.x upgrade. 3.x changed the storage
        # format of workflow inputs/outputs: it can read rows written by 2.x,
        # but 2.x cannot read rows written by 3.x. Changing the version keeps
        # any in-flight 2.x workflows from being handed to a 3.x executor (and
        # vice versa) while both are briefly running. Bump it again on the next
        # such upgrade.
        "application_version": os.environ.get("APP_VERSION", "0.2.0"),
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
        # 3.x: `ordering=` (none/partition/topic) replaced 2.x's `in_order=`
        # boolean - see consumer_workflows.KAFKA_ORDERING for the modes.
        ordering=consumer_workflows.KAFKA_ORDERING,
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


HEALTH_TIMEOUT_SEC = 3.0


@app.get("/health")
async def health(response: Response):
    """Assert the system database is reachable, not just that uvicorn answers.

    Same reasoning as worker.py's probe: a consumer that has lost its system
    database cannot start a workflow for anything it reads off the topic, and
    should be replaced rather than left reporting healthy. The query is
    `limit=1` against an indexed table, on a thread, with a timeout - cheap
    enough to run on every probe interval.

    There is no public API for "is the Kafka poll thread alive", so this cannot
    prove the consumer is still consuming. Alert on consumer-group lag for
    that; it is the metric that actually answers the question.
    """
    try:
        await asyncio.wait_for(
            DBOS.list_workflows_async(limit=1, load_input=False, load_output=False),
            timeout=HEALTH_TIMEOUT_SEC,
        )
    except Exception as exc:  # includes asyncio.TimeoutError
        DBOS.logger.warning("Health check failed: %s", exc)
        response.status_code = 503
        return {"status": "unhealthy", "reason": "system database unreachable"}

    return {"status": "ok", "topic": KAFKA_TOPIC}
