"""
Kafka/Redpanda client config - the producer (worker side) and the consumer
config dict DBOS builds its consumer from (consumer.py side).

Redpanda is Kafka-wire-compatible, so any Kafka client library works
unchanged against it. KAFKA_BOOTSTRAP_SERVERS just needs to point at
whichever cluster is live - the local single-node Redpanda container here,
or your real cluster in prod.
"""

# Defer annotation evaluation so `Producer | None` (PEP 604 syntax) doesn't get
# evaluated at import time - lets this module run on Python 3.9, not just the
# container's 3.12.
from __future__ import annotations

import json
import logging
import os

from confluent_kafka import Producer

from constants import KAFKA_TOPIC

logger = logging.getLogger(__name__)

KAFKA_BOOTSTRAP_SERVERS = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "redpanda:9092")

_producer: Producer | None = None


def get_producer() -> Producer:
    global _producer
    if _producer is None:
        _producer = Producer({"bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS})
    return _producer


def _delivery_report(err, msg) -> None:
    if err is not None:
        logger.error("Kafka delivery failed for key=%s: %s", msg.key(), err)
    else:
        logger.info(
            "Kafka event delivered to %s [partition %s, offset %s]",
            msg.topic(),
            msg.partition(),
            msg.offset(),
        )


def publish_order_processed(order_id: str, item: str, quantity: int) -> None:
    """Publish an 'order.processed' business event. Called by the worker
    once an order has finished processing."""
    producer = get_producer()

    event = {
        "event_type": "order.processed",
        "order_id": order_id,
        "item": item,
        "quantity": quantity,
    }

    producer.produce(
        topic=KAFKA_TOPIC,
        key=order_id.encode(),
        value=json.dumps(event).encode(),
        callback=_delivery_report,
    )
    # flush() blocks until the broker acks (or the timeout hits) - fine here
    # since this runs inside a DBOS step that's already doing slow work.
    # For higher-throughput producers, call poll() periodically instead and
    # flush() only on shutdown.
    #
    # flush() returns the number of messages STILL undelivered when it returns.
    # If the broker was slow/down we'd otherwise return as if the event was
    # published; raising instead fails the DBOS step so it retries, giving
    # genuine at-least-once delivery.
    remaining = producer.flush(timeout=5)
    if remaining > 0:
        raise RuntimeError(
            f"Kafka flush timed out with {remaining} event(s) undelivered "
            f"for order {order_id}"
        )


def close_producer() -> None:
    """Flush and release the module-level producer. Called on worker shutdown
    so any buffered events are delivered before the process exits."""
    global _producer
    if _producer is not None:
        _producer.flush(timeout=5)
        _producer = None


def consumer_config(group_id: str) -> dict:
    """Build the librdkafka config dict for the DBOS Kafka consumer.

    We hand DBOS a config, not a Consumer: @DBOS.kafka_consumer constructs the
    Consumer itself, owns the poll loop, and adds its own `error_cb`. A fresh
    dict is returned per call because DBOS mutates what it's given.

    Note what is NOT set here: `enable.auto.commit`. The old hand-rolled loop
    turned auto-commit off and committed after each DB write, because the commit
    was the only record that a message had been handled. DBOS's loop never
    commits manually, so disabling auto-commit would mean offsets never advance
    and every restart replays the whole topic. Durability doesn't depend on the
    offset anymore: the poll loop enqueues the workflow into Postgres before
    moving on, and the workflow ID is derived from the message's
    topic/partition/group/offset - so a replay enqueues an ID that already
    exists and is deduplicated instead of re-running. Let auto-commit do its
    thing.

    auto.offset.reset=earliest means a brand-new group starts from the beginning
    of the topic rather than skipping existing messages. DBOS defaults it to the
    same value if omitted; it's spelled out here so the behaviour is visible.

    For a cluster that needs TLS/SASL, add the `security.protocol`/`sasl.*` keys
    here - they're plain librdkafka config and pass straight through.
    """
    return {
        "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
        "group.id": group_id,
        "auto.offset.reset": "earliest",
    }
