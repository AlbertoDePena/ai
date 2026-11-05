# Shared local dev stack

Backing services for local development on this machine. **One stack, shared by
every repo** — start it once and leave it running. Repos don't get their own
copies; they get their own database, bucket and topics inside this one.

```bash
docker-compose up -d        # start (idempotent)
docker-compose ps           # what's up
docker-compose logs -f postgres
docker-compose down         # stop, keep data
docker-compose down -v      # stop and delete EVERY repo's data
```

`down -v` is machine-wide now. It wipes every project's databases and buckets,
not just the one you're working in.

## Endpoints

| Service | Where | Credentials |
|---|---|---|
| Postgres | `localhost:5432` | `crane_admin` / `P@55word!` |
| S3 API (Silo) | http://localhost:9000 | `minioadmin` / `minioadmin` |
| S3 console | http://localhost:9001 | same |
| Mailpit UI | http://localhost:8025 | — |
| SMTP | `localhost:1025` | any / any |
| Kafka (Redpanda) | `localhost:19092` | — |
| Redpanda console | http://localhost:8080 | — |
| Grafana (otel-lgtm) | http://localhost:3000 | anonymous admin, no login |
| OTLP gRPC | `localhost:4317` | — |
| OTLP HTTP | http://localhost:4318 | — |

## Onboarding an app

Each app carves out its own slice. From this directory:

```bash
# a database
docker exec -i postgres psql -U crane_admin -d postgres \
  -c 'CREATE DATABASE myapp_main'

# a bucket
docker exec -i s3 mc alias set local http://localhost:9000 minioadmin minioadmin
docker exec -i s3 mc mb --ignore-existing local/myapp

# topics (or let the app create them)
docker exec -i redpanda rpk topic create myapp.events
```

Then put this in the app's own `.env` — the app repo holds no compose file:

```
DATABASE_URL=postgresql://crane_admin:P%4055word%21@localhost:5432/myapp_main
AWS_ENDPOINT_URL=http://localhost:9000
AWS_ACCESS_KEY_ID=minioadmin
AWS_SECRET_ACCESS_KEY=minioadmin
AWS_REGION=us-east-1
S3_BUCKET=myapp
KAFKA_BOOTSTRAP_SERVERS=localhost:19092
SMTP_HOST=localhost
SMTP_PORT=1025
OTEL_SERVICE_NAME=myapp
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
# HTTP-only exporters (Pydantic Logfire, the DBOS Python SDK) instead want:
# OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
# OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

`OTEL_SERVICE_NAME` is per app and not optional — every app reports into the
same Grafana, and that name is what separates their traces.

## Apps running inside Docker

The host ports above are for processes on the host. A containerized app joins
this stack's network instead and uses service names:

```yaml
# the app's own compose file
services:
  myapp:
    networks: [devstack]
    environment:
      DATABASE_URL: postgresql://crane_admin:...@postgres:5432/myapp_main
      AWS_ENDPOINT_URL: http://s3:9000
      KAFKA_BOOTSTRAP_SERVERS: redpanda:9092
      SMTP_HOST: mailpit
      OTEL_EXPORTER_OTLP_ENDPOINT: http://grafana:4317
networks:
  devstack:
    name: docker_default   # this stack's network: <its directory>_default
    external: true
```

Don't add app services to the compose file in this directory — it is shared
infrastructure, and `down` here would take every app with it.
