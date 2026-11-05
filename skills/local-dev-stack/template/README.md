# Local dev stack — ${APP_NAME}

Backing services for local development. One stack per repo; ports and container
names come from `.env`, so this can run alongside another repo's stack.

```bash
cd docker
cp .env.example .env     # first time only
docker-compose up -d
docker-compose ps
docker-compose logs -f postgres
docker-compose down      # stop, keep data
docker-compose down -v   # stop, wipe data volumes
```

`${APP_NAME}_s3_setup` is a one-shot bucket creator — `exited (0)` is success.

Telemetry lands in Grafana: traces in Tempo, logs in Loki, metrics in
Prometheus, all pre-wired as datasources. It persists across restarts, so
yesterday's traces are still queryable.

## Endpoints

| Service | Where | Credentials |
|---|---|---|
| Postgres | `localhost:${POSTGRES_PORT}` | `${POSTGRES_USER}` / `${POSTGRES_PASSWORD}`, db `${POSTGRES_DB}` |
| S3 API (Silo) | http://localhost:${S3_PORT} | `${MINIO_ROOT_USER}` / `${MINIO_ROOT_PASSWORD}`, bucket `${S3_BUCKET}` |
| S3 console | http://localhost:${S3_CONSOLE_PORT} | same |
| Mailpit UI | http://localhost:${MAILPIT_UI_PORT} | — |
| SMTP | `localhost:${MAILPIT_SMTP_PORT}` | any / any |
| Kafka (Redpanda) | `localhost:${KAFKA_PORT}` | — |
| Redpanda console | http://localhost:${KAFKA_CONSOLE_PORT} | — |
| Grafana (otel-lgtm) | http://localhost:${OTEL_UI_PORT} | anonymous admin, no login |
| OTLP gRPC | `localhost:${OTEL_OTLP_GRPC_PORT}` | — |
| OTLP HTTP | http://localhost:${OTEL_OTLP_HTTP_PORT} | — |

## App config

```
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${POSTGRES_PORT}/${POSTGRES_DB}
AWS_ENDPOINT_URL=http://localhost:${S3_PORT}
AWS_ACCESS_KEY_ID=${MINIO_ROOT_USER}
AWS_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD}
AWS_REGION=us-east-1
S3_BUCKET=${S3_BUCKET}
KAFKA_BOOTSTRAP_SERVERS=localhost:${KAFKA_PORT}
SMTP_HOST=localhost
SMTP_PORT=${MAILPIT_SMTP_PORT}
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:${OTEL_OTLP_GRPC_PORT}
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
# HTTP-only exporters (Pydantic Logfire, the DBOS Python SDK) instead want:
# OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:${OTEL_OTLP_HTTP_PORT}
# OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Containers reach each other by service name on the compose network
(`postgres:5432`, `silo:9000`, `redpanda:9092`, `mailpit:1025`,
`otel:4317`) — the host ports above are only for processes running
outside Docker.
