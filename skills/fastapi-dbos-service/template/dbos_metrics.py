"""
DBOS fleet metrics: queue depth, workflow outcomes, and per-process liveness.

These answer two different questions and therefore take two different shapes -
the distinction matters, because getting it backwards produces a metric that
looks fine and tells you nothing:

- **How much work is in flight, app-wide?** That lives in the system database,
  which is shared by every replica, so it is sampled once per tick by a
  SCHEDULED DBOS WORKFLOW. A DBOS schedule is owned by the application, not the
  process: one workflow is enqueued per tick and whichever replica dequeues it
  does the sampling. That is exactly right here - the counts are app-wide, and
  N replicas must not produce N copies of them.

- **Is THIS replica still working?** That cannot come from a scheduled
  workflow, for the same reason: one beat per tick across the whole app proves
  "some task is alive", never "every task is alive". So it is a per-process
  OBSERVABLE GAUGE, reported by every replica on every export interval and
  keyed by `service.instance.id` (see otel_setup.py - set DBOS__VMID to the
  ECS task id / pod name so the series are distinguishable).

Together they give the alert neither can give alone - "work is waiting and this
replica has completed nothing":

    dbos_worker_idle_seconds > 300
      and on() max(dbos_workflows{status="ENQUEUED"}) > 0

Without the second clause that alert fires on any idle fleet; without the first
it never fires at all. This is the gap `/health` deliberately leaves open: the
probe proves the process answers and can reach the system database, not that its
dequeue loop is advancing.

Imported by every process (it registers a workflow - see worker.py), but the
schedule is APPLIED in only one of them, the same way consumer.py owns the Kafka
poller.
"""

import os
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

from dbos import DBOS, WorkflowStatusString
from opentelemetry.metrics import CallbackOptions, Observation

import otel_setup

meter = otel_setup.get_meter(__name__)

# Cron for the sampling workflow. Croniter syntax with an optional leading
# seconds field; once a minute is plenty for a gauge scraped every 15-60s.
SAMPLE_SCHEDULE = os.environ.get("DBOS_METRICS_SCHEDULE", "* * * * *")
SCHEDULE_NAME = "dbos-workflow-sample"

# How far back "completed" looks. Keep it comfortably wider than the scrape
# interval so a gauge is never read between two empty windows.
COMPLETED_LOOKBACK = timedelta(minutes=15)

# Cap on rows pulled per status group per tick. A fleet that exceeds this is
# past the point where listing rows is the right way to count them - swap in a
# COUNT(*) against the system database, or DBOS Conductor.
SAMPLE_LIMIT = 2000

IN_FLIGHT_STATUSES = [
    WorkflowStatusString.PENDING.value,
    WorkflowStatusString.ENQUEUED.value,
    WorkflowStatusString.DELAYED.value,
]
TERMINAL_STATUSES = [
    WorkflowStatusString.SUCCESS.value,
    WorkflowStatusString.ERROR.value,
    WorkflowStatusString.CANCELLED.value,
    WorkflowStatusString.MAX_RECOVERY_ATTEMPTS_EXCEEDED.value,
]

# Metric names carry no `_seconds` suffix on purpose: the OTLP -> Prometheus
# translation appends one for `unit="s"`, so `dbos.worker.idle` becomes
# `dbos_worker_idle_seconds`. Naming it `...idle_seconds` here would produce
# `dbos_worker_idle_seconds_seconds`. For the same reason counts use a braced
# unit (`{workflow}`), which the translation strips - `unit="1"` would append
# `_ratio`.
workflows_gauge = meter.create_gauge(
    "dbos.workflows",
    unit="{workflow}",
    description="DBOS workflows in flight by status, app-wide",
)
workflows_completed_gauge = meter.create_gauge(
    "dbos.workflows.completed",
    unit="{workflow}",
    description="DBOS workflows that reached a terminal status inside the lookback window, app-wide",
)


# ---------------------------------------------------------------------------
# Per-process liveness
# ---------------------------------------------------------------------------

_process_started_at = time.monotonic()
_last_workflow_completed_at: float | None = None


def record_workflow_completed() -> None:
    """Mark that a workflow just finished in THIS process.

    Call it at the end of every workflow (see workflows.py /
    consumer_workflows.py). This is process-local telemetry, not workflow state:
    it is deliberately not a `@DBOS.step()`, so a replayed workflow re-records
    it - which is what you want, since a replay means this process really is
    working. It is the one global the "don't mutate globals from a workflow"
    rule doesn't apply to, because nothing reads it back to make a decision and
    it never affects a workflow's result.
    """
    global _last_workflow_completed_at
    _last_workflow_completed_at = time.monotonic()


def _observe_idle_seconds(options: CallbackOptions) -> Iterable[Observation]:
    """Seconds since this process last completed a workflow.

    Before the first completion this reports process uptime instead of nothing,
    so a replica that has never done any work still produces a series - which is
    the case the alert above has to catch.
    """
    reference = (
        _last_workflow_completed_at
        if _last_workflow_completed_at is not None
        else _process_started_at
    )
    yield Observation(
        time.monotonic() - reference,
        {"ever_completed": _last_workflow_completed_at is not None},
    )


meter.create_observable_gauge(
    "dbos.worker.idle",
    unit="s",
    description="Seconds since this process last completed a DBOS workflow",
    callbacks=[_observe_idle_seconds],
)


# ---------------------------------------------------------------------------
# App-wide sampling (scheduled workflow)
# ---------------------------------------------------------------------------


@DBOS.step(retries_allowed=True, max_attempts=3, interval_seconds=1)
def sample_workflow_counts_step() -> dict[str, dict[str, int]]:
    """Count workflows by status, straight out of the system database.

    The database is the durable source of truth, so these numbers survive
    restarts and stay consistent no matter which replica does the sampling.
    `load_input`/`load_output` are off: we need the status column, not the
    payloads.
    """
    in_flight = {status: 0 for status in IN_FLIGHT_STATUSES}
    for wf in DBOS.list_workflows(
        status=IN_FLIGHT_STATUSES,
        load_input=False,
        load_output=False,
        limit=SAMPLE_LIMIT,
    ):
        in_flight[wf.status] = in_flight.get(wf.status, 0) + 1

    since = (datetime.now(timezone.utc) - COMPLETED_LOOKBACK).isoformat()
    completed = {status: 0 for status in TERMINAL_STATUSES}
    for wf in DBOS.list_workflows(
        status=TERMINAL_STATUSES,
        completed_after=since,
        load_input=False,
        load_output=False,
        limit=SAMPLE_LIMIT,
    ):
        completed[wf.status] = completed.get(wf.status, 0) + 1

    return {"in_flight": in_flight, "completed": completed}


@DBOS.step()
def publish_workflow_counts_step(counts: dict[str, dict[str, int]]) -> None:
    """Write the sampled counts onto the gauges.

    Its own step so a failure to export doesn't re-run the query, and so a
    replayed sampling workflow doesn't double-publish (a completed step is never
    re-executed).
    """
    window = f"{int(COMPLETED_LOOKBACK.total_seconds())}s"
    for status, count in counts["in_flight"].items():
        workflows_gauge.set(count, {"status": status})
    for status, count in counts["completed"].items():
        workflows_completed_gauge.set(count, {"status": status, "window": window})

    DBOS.logger.debug("Sampled DBOS workflow counts: %s", counts)


@DBOS.workflow()
def sample_workflow_counts(scheduled_time: datetime, context: Any) -> None:
    """Scheduled sampler. One durable workflow execution per tick, app-wide.

    The two arguments are fixed by DBOS's schedule API: the tick's scheduled
    time and the schedule's `context`.
    """
    publish_workflow_counts_step(sample_workflow_counts_step())


def apply_schedule() -> None:
    """Register the sampling schedule. Call AFTER DBOS.launch(), in ONE process.

    `apply_schedules` upserts by name and is idempotent, so restarts are safe -
    but it replaces the whole definition, so every field has to be passed every
    time. Applying it from a single process keeps ownership obvious; the
    workflow it enqueues can still be dequeued and run by any replica, which is
    why every process imports this module.
    """
    DBOS.apply_schedules(
        [
            {
                "schedule_name": SCHEDULE_NAME,
                "workflow_fn": sample_workflow_counts,
                "schedule": SAMPLE_SCHEDULE,
                "context": None,
            }
        ]
    )
