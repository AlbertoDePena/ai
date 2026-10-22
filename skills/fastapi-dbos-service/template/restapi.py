"""
Outbound calls to an external REST API, over httpx.

The consumer's workflow can do two kinds of thing with an event: write it to
our own Postgres (appdb.py) or hand it to something else. This module is the
"something else" - one place that owns the base URL, auth header, and timeout
for the downstream service, the same way s3.py owns the boto3 client config.

Named restapi.py, not http.py: a local http.py would shadow the stdlib `http`
package that httpx itself imports (same reasoning as smtp.py vs email.py).

The client is SYNC on purpose. Callers are DBOS steps, which run on DBOS's
background threads, not on uvicorn's event loop - so blocking I/O is correct
here, and an async client would need a loop that doesn't exist on that thread.
(The async rule still holds everywhere else: see CLAUDE.md.)

If EXTERNAL_API_URL is unset the step that calls this skips the call and logs -
so the template boots with no downstream service wired up. Set it to point at
your own API.
"""

from __future__ import annotations

import logging
import os

import httpx

logger = logging.getLogger(__name__)

# Unset by default: the bundled compose stack has no downstream API to call.
EXTERNAL_API_URL = os.environ.get("EXTERNAL_API_URL")
EXTERNAL_API_TOKEN = os.environ.get("EXTERNAL_API_TOKEN")
EXTERNAL_API_TIMEOUT = float(os.environ.get("EXTERNAL_API_TIMEOUT", "10"))

_client: httpx.Client | None = None


def get_client() -> httpx.Client:
    """Module-level client so connections are pooled and reused across steps.
    httpx.Client is thread-safe, which matters because DBOS runs steps on a
    thread pool."""
    global _client
    if _client is None:
        headers = {"Content-Type": "application/json"}
        if EXTERNAL_API_TOKEN:
            headers["Authorization"] = f"Bearer {EXTERNAL_API_TOKEN}"
        _client = httpx.Client(
            base_url=EXTERNAL_API_URL or "",
            headers=headers,
            timeout=EXTERNAL_API_TIMEOUT,
        )
    return _client


def post_json(path: str, payload: dict, idempotency_key: str) -> dict | None:
    """POST a JSON body to the downstream API.

    `idempotency_key` goes out as an Idempotency-Key header. The calling step is
    retried on failure, and a retry can mean the first attempt actually landed
    and only the response was lost - the key is what lets the downstream service
    recognize the repeat and not act on it twice. DBOS makes our side
    exactly-once; only the downstream can make its own side exactly-once.

    raise_for_status() is deliberate: a 4xx/5xx must propagate out so the DBOS
    step fails and retries (or, after max_attempts, fails the workflow visibly)
    rather than being swallowed as a success.
    """
    response = get_client().post(
        path, json=payload, headers={"Idempotency-Key": idempotency_key}
    )
    response.raise_for_status()
    logger.info(
        "POST %s -> %s (idempotency-key=%s)", path, response.status_code, idempotency_key
    )
    if not response.content:
        return None
    return response.json()


def close_client() -> None:
    """Release the pooled connections. Called from the consumer's lifespan
    shutdown."""
    global _client
    if _client is not None:
        _client.close()
        _client = None
