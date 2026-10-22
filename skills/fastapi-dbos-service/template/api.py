import json
import logging
import os
import uuid
from contextlib import asynccontextmanager

import aioboto3
from dbos import DBOSClient, EnqueueOptions
from fastapi import Depends, FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from pydantic import BaseModel

import appdb
import otel_setup
from azure_auth import DEV_MODE, get_current_user
from constants import BUCKET_NAME, PROCESS_ORDER_WORKFLOW, QUEUE_NAME
from s3 import s3_client_kwargs

otel_setup.configure_otel()

logger = logging.getLogger(__name__)
tracer = otel_setup.get_tracer(__name__)
meter = otel_setup.get_meter(__name__)

orders_created_counter = meter.create_counter(
    "orders.created", description="Number of orders submitted via the API"
)

DBOS_DATABASE_URL = os.environ["DBOS_DATABASE_URL"]

# DBOSClient is how a process *outside* a DBOS app (our API) enqueues
# workflows that a DBOS app (worker.py) will later dequeue and run. It
# writes directly to the DBOS system tables in Postgres - this replaces
# the old sqs.send_message() call entirely.
dbos_client = DBOSClient(
    system_database_url=DBOS_DATABASE_URL,
)

s3_session = aioboto3.Session()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Open the async psycopg pool for reading the consumer's read model. The
    # API's endpoints run on the event loop, so DB access must be async (a sync
    # call here would block every concurrent request) - appdb exposes an async
    # path over the same table the consumer writes with its sync path. The
    # schema itself is applied out of band by dbmate (./migrate.sh), not here.
    await appdb.open_apool()
    yield
    await appdb.close_apool()
    dbos_client.destroy()


app = FastAPI(title="FastAPI AWS Demo", lifespan=lifespan)
templates = Jinja2Templates(directory="templates")

FastAPIInstrumentor.instrument_app(app, excluded_urls="health")
HTTPXClientInstrumentor().instrument()


class OrderIn(BaseModel):
    item: str
    quantity: int


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return RedirectResponse(url="/dashboard")


@app.get("/me")
async def read_current_user(user: dict = Depends(get_current_user)):
    return user


@app.post("/orders")
async def create_order(order: OrderIn, user: dict = Depends(get_current_user)):
    order_id = str(uuid.uuid4())

    with tracer.start_as_current_span("create_order") as span:
        span.set_attribute("order.id", order_id)
        span.set_attribute("order.item", order.item)

        record = {
            "id": order_id,
            "item": order.item,
            "quantity": order.quantity,
            "status": "queued",
            "created_by": user.get("preferred_username"),
        }

        # Write the initial record to S3 - our simple shared "database"
        async with s3_session.client("s3", **s3_client_kwargs()) as s3:
            await s3.put_object(
                Bucket=BUCKET_NAME,
                Key=f"orders/{order_id}.json",
                Body=json.dumps(record).encode(),
                ContentType="application/json",
            )

        # Enqueue the durable workflow instead of sqs.send_message(). The
        # workflow may not actually run until seconds later, possibly on a
        # different worker container. NOTE: DBOS 1.14 does not propagate OTel
        # trace context across the enqueue, so the workflow's spans land in a
        # separate trace from this request - see README.
        options: EnqueueOptions = {
            "queue_name": QUEUE_NAME,
            "workflow_name": PROCESS_ORDER_WORKFLOW,
        }
        await dbos_client.enqueue_async(options, order_id)

        orders_created_counter.add(1, {"item": order.item})
        logger.info("Order %s created and enqueued for processing", order_id)

    return record


@app.get("/orders/{order_id}")
async def get_order(order_id: str):
    async with s3_session.client("s3", **s3_client_kwargs()) as s3:
        try:
            resp = await s3.get_object(Bucket=BUCKET_NAME, Key=f"orders/{order_id}.json")
            body = await resp["Body"].read()
            return json.loads(body)
        except s3.exceptions.NoSuchKey:
            return {"error": "not found"}


@app.get("/orders")
async def list_orders():
    async with s3_session.client("s3", **s3_client_kwargs()) as s3:
        resp = await s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix="orders/")
        orders = []
        for obj in resp.get("Contents", []):
            got = await s3.get_object(Bucket=BUCKET_NAME, Key=obj["Key"])
            body = await got["Body"].read()
            orders.append(json.loads(body))
        orders.sort(key=lambda o: o["id"])
        return orders


# The /orders endpoints above read the source of truth (the JSON in S3).
# These /processed-orders endpoints read the *read model* in Postgres that the
# Kafka consumer (consumer.py) projects from order.processed events - a small
# CQRS-style split. They use appdb's async path so they don't block the loop.
@app.get("/processed-orders")
async def read_processed_orders(limit: int = 50):
    return await appdb.list_processed_orders(limit)


@app.get("/processed-orders/{order_id}")
async def read_processed_order(order_id: str):
    order = await appdb.get_processed_order(order_id)
    if order is None:
        return {"error": "not found"}
    return order


@app.get("/dashboard")
async def dashboard(request: Request, user: dict = Depends(get_current_user)):
    """Server-side rendered page: fetches order state and renders straight to HTML."""
    orders = await list_orders()
    return templates.TemplateResponse(
        "dashboard.html",
        {
            "request": request,
            "user": user,
            "orders": orders,
            "dev_mode": DEV_MODE,
        },
    )
