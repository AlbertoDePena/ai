"""
The application Postgres database - SEPARATE from the DBOS system database.

The worker and the consumer share one system database for their workflow/queue
state (DBOS_DATABASE_URL -> orders_api_dbos);
this module talks to the other database (APP_DATABASE_URL -> orders_api), holding the
application's own data: a read model of `order.processed` events in a
`processed_orders` table (its schema is decided by the role's search_path, set
by provisioning). Keeping them apart means app schema changes never touch
DBOS's internal tables.

Two access paths over the same table, because the two callers have different
concurrency models (see `go`/async notes in the README):

- **Sync** (`ConnectionPool`) - used by the consumer's DBOS steps
  (`consumer_workflows.py`), which DBOS runs on its own background threads,
  where blocking DB calls are fine.
- **Async** (`AsyncConnectionPool`) - used by `api.py`, whose endpoints run on
  the asyncio event loop, where a blocking call would stall every other
  request. psycopg 3 is async-native, so this is the same driver, not a new
  dependency.

Each process opens only the pool it uses; never share a pool across the
sync/async boundary.
"""

from __future__ import annotations

import os

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool, ConnectionPool

APP_DATABASE_URL = os.environ["APP_DATABASE_URL"]

# Table name is unqualified on purpose: the application role's search_path
# (set by provisioning, e.g. `<namespace>, public`) decides which schema it
# lands in, so this code isn't tied to a specific schema name. The table itself
# is managed out of band by dbmate (db/migrations + ./migrate.sh), not here.
_TABLE = "processed_orders"
_SELECT_COLS = "order_id, item, quantity, processed_at"


# --- Sync path (consumer.py) ------------------------------------------------

_pool: ConnectionPool | None = None


def get_pool() -> ConnectionPool:
    global _pool
    if _pool is None:
        _pool = ConnectionPool(APP_DATABASE_URL, min_size=1, max_size=5, open=True)
    return _pool


def save_processed_order(order_id: str, item: str, quantity: int) -> None:
    """Upsert one processed order. ON CONFLICT DO NOTHING keeps this idempotent.

    The consumer's DBOS workflow-ID dedup already stops a redelivered message
    from re-running the step, so this is defence in depth - it still matters for
    a backfill, or for a topic replayed under a different consumer group (a
    different workflow ID, hence a genuinely new workflow).
    """
    with get_pool().connection() as conn:
        conn.execute(
            f"""
            INSERT INTO {_TABLE} (order_id, item, quantity)
            VALUES (%s, %s, %s)
            ON CONFLICT (order_id) DO NOTHING
            """,
            (order_id, item, quantity),
        )


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


# --- Async path (api.py) ----------------------------------------------------

_apool: AsyncConnectionPool | None = None


async def open_apool() -> None:
    """Open the async pool. Call once from the API's lifespan startup."""
    global _apool
    if _apool is None:
        _apool = AsyncConnectionPool(APP_DATABASE_URL, min_size=1, max_size=5, open=False)
        await _apool.open()


async def close_apool() -> None:
    """Close the async pool. Call from the API's lifespan shutdown."""
    global _apool
    if _apool is not None:
        await _apool.close()
        _apool = None


async def list_processed_orders(limit: int = 50) -> list[dict]:
    # dict_row returns {column: value} rows; FastAPI serializes the datetime.
    async with _apool.connection() as conn:
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute(
                f"SELECT {_SELECT_COLS} FROM {_TABLE} "
                "ORDER BY processed_at DESC LIMIT %s",
                (limit,),
            )
            return await cur.fetchall()


async def get_processed_order(order_id: str) -> dict | None:
    async with _apool.connection() as conn:
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute(
                f"SELECT {_SELECT_COLS} FROM {_TABLE} WHERE order_id = %s",
                (order_id,),
            )
            return await cur.fetchone()
