"""
The Kafka-driven durable workflow.

This is the event-consumption counterpart to workflows.py. The two are the same
idea started two different ways: there, the API explicitly enqueues onto a DBOS
queue; here, @DBOS.kafka_consumer polls a topic and starts one workflow per
message. Past the decorator it's the same programming model - a workflow made
of @DBOS.step()s, with its state in Postgres.

Why this replaced the hand-rolled poll loop (manual commit + idempotent upsert):

- DBOS derives each workflow's ID deterministically from the message's
  coordinates - `kafka-unique-id-<topic>-<partition>-<group.id>-<offset>` - and
  enqueueing an ID that already exists is an upsert, not a second workflow. A
  redelivered message (consumer rebalance, restart, at-least-once broker) is
  therefore a no-op rather than a re-run: exactly-once *processing* on top of
  at-least-once *delivery*, without us tracking offsets by hand.
- Each side effect is its own step, so a crash between them resumes from the
  last completed one. The Postgres write isn't redone just because the
  downstream API call failed, and vice versa.
- A message we can never handle (bad JSON, a downstream 400) fails its workflow
  and is left in the system DB with status ERROR - an inspectable dead letter,
  queryable with the DBOS CLI - while the consumer moves on instead of spinning
  on the same offset forever.

Imported by BOTH worker.py and consumer.py, on purpose. The two processes are
one DBOS app sharing one system database, so each must be able to execute any
workflow it dequeues or recovers - a process that has not registered this
function would fail such a workflow with "not a registered workflow function".
Importing this module is what registers it.

What this module deliberately does NOT do is attach the Kafka poller. That is
applied in consumer.py, so only the consumer process polls the topic, while
both processes can run the workflows those messages produce.
"""

import json
import logging

import appdb
import otel_setup
import restapi
from dbos import DBOS, KafkaMessage

logger = logging.getLogger(__name__)
meter = otel_setup.get_meter(__name__)

events_projected_counter = meter.create_counter(
    "orders.events_projected",
    description="Number of order.processed events written to the read model",
)

# Read by consumer.py, which is where the Kafka poller is attached.
# in_order=False lets DBOS run workflows for different messages concurrently,
# which is what you want for an idempotent projection like this one. Flip it to
# True and DBOS gives the topic its own queue with concurrency=1, processing
# messages strictly in offset order - correct when later events overwrite
# earlier ones for the same key, slower otherwise. (in_order=True doesn't work
# with regex topic selectors.)
KAFKA_IN_ORDER = False


@DBOS.step()
def save_processed_order_step(order_id: str, item: str, quantity: int) -> None:
    """Project the event into the application Postgres database.

    Uses appdb's SYNC pool: DBOS runs steps on its own threads, not on uvicorn's
    event loop, so blocking DB calls belong here (see CLAUDE.md's async rule).

    The upsert's ON CONFLICT DO NOTHING is now belt-and-suspenders rather than
    the thing that makes replays safe - DBOS's workflow-ID dedup already stops
    the step from running twice. It's kept because the table can also be written
    by a backfill or a replayed topic under a *different* consumer group, which
    produces a different workflow ID and so is a genuinely new workflow.
    """
    appdb.save_processed_order(order_id, item, quantity)
    events_projected_counter.add(1)
    logger.info("Projected order %s into the read model", order_id)


@DBOS.step(retries_allowed=True, max_attempts=4, interval_seconds=1.0, backoff_rate=2.0)
def notify_downstream_step(order_id: str, item: str, quantity: int) -> None:
    """Hand the event to an external REST API.

    retries_allowed is on because a network call is the classic transient
    failure: DBOS retries this step with exponential backoff (1s, 2s, 4s) and
    only fails the workflow if all four attempts fail. The Postgres write above
    has already been recorded as complete, so a retry here never re-writes it.

    No EXTERNAL_API_URL configured means no downstream service to call, which is
    the default in the bundled compose stack - log and return rather than fail.
    """
    if not restapi.EXTERNAL_API_URL:
        logger.info(
            "EXTERNAL_API_URL unset; skipping downstream notification for order %s",
            order_id,
        )
        return

    restapi.post_json(
        "/orders",
        {"order_id": order_id, "item": item, "quantity": quantity},
        idempotency_key=order_id,
    )


@DBOS.workflow()
def process_order_event_workflow(msg: KafkaMessage) -> None:
    """One workflow per Kafka message.

    The signature is fixed by DBOS - exactly one KafkaMessage parameter.

    @DBOS.kafka_consumer is NOT stacked on top of this, the way DBOS's docs
    show. It registers a poll thread that DBOS.launch() starts in whichever
    process imported the decorated module, so stacking it here would make the
    worker poll Kafka too, simply for importing this file to register the
    workflow. Instead consumer.py applies it to this function at startup -
    `DBOS.kafka_consumer(...)(process_order_event_workflow)` is exactly what the
    decorator form does, just done in one process rather than every importer.
    What it enqueues is still the already-registered workflow below.

    Decoding happens in the workflow body, not a step: it's pure, deterministic
    work on the input, so replaying it costs nothing and recording it in
    Postgres would only add a round trip.
    """
    if msg.value is None:
        raise ValueError(
            f"Kafka message at {msg.topic}[{msg.partition}]@{msg.offset} has no value"
        )

    event = json.loads(msg.value)
    order_id = event["order_id"]
    DBOS.logger.info(
        "Handling %s for order %s (offset %s)",
        event.get("event_type"),
        order_id,
        msg.offset,
    )

    save_processed_order_step(order_id, event["item"], event["quantity"])
    notify_downstream_step(order_id, event["item"], event["quantity"])
