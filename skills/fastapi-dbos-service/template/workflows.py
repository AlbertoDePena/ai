"""
The durable "long-running task" logic, expressed as a DBOS workflow.

Unlike the SQS version, this doesn't need a hand-rolled poll loop with
manual retry/ack logic - DBOS persists workflow and step state in Postgres,
so if the worker process crashes mid-step, DBOS resumes it from the last
completed step on restart instead of losing or double-processing the order.

Only imported by worker.py. api.py never imports this module directly -
it only references the workflow by name through DBOSClient, which is the
whole point of keeping the worker as an independently-scalable service.
"""

import json
import logging
import time

import boto3
from dbos import DBOS

import otel_setup
from constants import BUCKET_NAME
from kafka import publish_order_processed
from s3 import s3_client_kwargs
from smtp import send_email

logger = logging.getLogger(__name__)
tracer = otel_setup.get_tracer(__name__)
meter = otel_setup.get_meter(__name__)

orders_processed_counter = meter.create_counter(
    "orders.processed", description="Number of orders fully processed by the worker"
)
processing_duration_histogram = meter.create_histogram(
    "orders.processing_duration_seconds", description="Time spent processing an order"
)

s3 = boto3.client("s3", **s3_client_kwargs())


def _update_order_status(order_id: str, status: str) -> dict:
    key = f"orders/{order_id}.json"
    obj = s3.get_object(Bucket=BUCKET_NAME, Key=key)
    record = json.loads(obj["Body"].read())
    record["status"] = status
    s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=json.dumps(record).encode())
    return record


@DBOS.step()
def process_order_step(order_id: str) -> dict:
    with tracer.start_as_current_span("process_order_step") as span:
        span.set_attribute("order.id", order_id)
        start = time.time()

        logger.info("Processing order %s", order_id)
        _update_order_status(order_id, "processing")

        # Simulate slow work: a real job might resize a video, run an ML
        # inference call, generate a PDF, call a slow downstream API, etc.
        time.sleep(8)

        record = _update_order_status(order_id, "done")
        duration = time.time() - start

        orders_processed_counter.add(1)
        processing_duration_histogram.record(duration)

        publish_order_processed(order_id, record["item"], record["quantity"])

        logger.info("Order %s done in %.1fs, order.processed event published", order_id, duration)
        return record


@DBOS.step()
def send_confirmation_email_step(order_id: str, to: str, item: str, quantity: int) -> None:
    """Send the order-confirmation email as its own durable step. DBOS records
    the step's success in Postgres, so a workflow replay (e.g. the process has
    crashed and recovered) won't resend an email that already went out; a
    failure here is retried rather than silently dropped."""
    subject = f"Order {order_id[:8]} confirmed"
    body = (
        f"Your order has been processed.\n\n"
        f"Order ID: {order_id}\n"
        f"Item:     {item}\n"
        f"Quantity: {quantity}\n"
    )
    send_email(to, subject, body)
    logger.info("Confirmation email sent for order %s to %s", order_id, to)


@DBOS.workflow()
def process_order_workflow(order_id: str) -> None:
    record = process_order_step(order_id)
    send_confirmation_email_step(
        order_id, record["created_by"], record["item"], record["quantity"]
    )
