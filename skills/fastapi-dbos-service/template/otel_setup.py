"""
OpenTelemetry setup for traces, metrics, and logs.

No collector/sidecar here - this exports OTLP directly to the .NET Aspire
Dashboard container, which speaks OTLP natively. In ECS/Fargate later, you'd
just swap OTEL_EXPORTER_OTLP_ENDPOINT to point at whatever collects it
(ADOT sidecar, Grafana Alloy, etc.) - nothing else in this file changes.
"""

import logging
import os

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

OTLP_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:18889")
SERVICE_NAME = os.environ.get("OTEL_SERVICE_NAME", "fastapi-aws-demo")

_configured = False


def configure_otel() -> None:
    """Idempotently wire up traces, metrics, and logs. Call once at startup."""
    global _configured
    if _configured:
        return
    _configured = True

    resource = Resource.create(
        {
            "service.name": SERVICE_NAME,
            "deployment.environment": os.environ.get("ENVIRONMENT", "local"),
        }
    )

    # --- Traces ---
    trace_provider = TracerProvider(resource=resource)
    trace_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True))
    )
    trace.set_tracer_provider(trace_provider)

    # --- Metrics ---
    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True),
        export_interval_millis=5000,  # short interval so you see data quickly in the demo
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

    # --- Logs ---
    # Attaches to the root logger, so plain `logging.getLogger(__name__)` calls
    # anywhere in the app get shipped as OTel log records, correlated with the
    # active trace/span automatically.
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTLP_ENDPOINT, insecure=True))
    )
    otel_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)

    root_logger = logging.getLogger()
    root_logger.addHandler(otel_handler)
    root_logger.setLevel(logging.INFO)

    # Also log to stdout. Without this the root logger only has the OTel
    # handler, so app logs (api.py, kafka.py, ...) ship to Aspire but never
    # appear in `docker logs` / the console - surprising for operators. DBOS
    # attaches its own stream handler, which is why only its logs show up
    # otherwise.
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s [%(name)s] %(message)s")
    )
    root_logger.addHandler(console_handler)

    logging.getLogger(__name__).info(
        "OpenTelemetry configured, exporting to %s as service '%s'", OTLP_ENDPOINT, SERVICE_NAME
    )


def get_tracer(name: str):
    return trace.get_tracer(name)


def get_meter(name: str):
    return metrics.get_meter(name)
