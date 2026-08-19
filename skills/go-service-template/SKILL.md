---
name: go-service-template
description: Use this skill whenever the user is building, scaffolding, structuring, or reviewing a Go service that will run as a container — whether it's an API (Swagger), an SSR UI (HTMX + Go templates + Tailwind), a background worker, a queue consumer, or an outbox relay. Also use when the user asks about Go repo layout, how to organize internal/ packages, how to add a service/repository layer with interface-based mocking, how to wire a transactional outbox pattern, how to structure multi-binary Go repos (cmd/api, cmd/ui, cmd/worker), or how to keep API/UI/worker entrypoints decoupled from shared business logic. Trigger even if the user doesn't say "template" explicitly — e.g. "how should I structure this Go service," "add a worker to this repo," "I need a transaction across two repos," or "should this be its own binary" are all in scope.
---

# Go Multi-Binary Service Template

This skill encodes an opinionated architecture for Go services deployed as containers. It covers three kinds of entrypoints — **API** (Swagger-documented), **SSR UI** (HTMX + Go templates + Tailwind), and any number of **background binaries** (queue consumers, outbox relays, cron jobs) — sharing one `internal/` library in one repo.

Full rationale, complete code samples, and the Dockerfile patterns live in `references/architecture.md`. Read it before generating any files — this SKILL.md is the quick-reference map, not the full spec.

## Core decisions (non-negotiable defaults for this template)

- **One repo, one `go.mod`, separate binaries.** Every independently-scalable responsibility gets its own `cmd/<name>/` — `cmd/api`, `cmd/ui`, `cmd/worker`, `cmd/outbox-relay`, and any future one. Never add a run-mode flag to an existing binary to combine responsibilities; add a new `cmd/` entry instead. "Worker" is a category, not one binary — a queue consumer needing N replicas and an outbox relay needing exactly 1 replica are both workers but must be separate binaries.
- **Single `internal/` tree**, organic subpackages (`config`, `log`, `otel`, `httpserver`, `queue`, `domain`, `service`, `repository`, `render`, `version`). Don't pre-split further than the concern warrants.
- **Layering, strictly one direction:** entrypoint edge type → `service` interface → `repository`/`queue`/`Transactor` interfaces → (real DB/queue, plugged in later). Handlers and consumers never call `repository` or `queue` directly — always through `service`.
- **Entry-point-owned edge types.** Each binary defines its own request/response shape, colocated with its handlers so nothing else imports them:
  - `cmd/api/handler` → `Request`/`Response` structs, JSON-tagged
  - `cmd/ui/handler` → `ViewModel` structs shaped for `html/template`
  - `cmd/worker/consumer` (and any other worker) → `Param`/`Input` structs matching the queue message body
  - `domain.User` (etc.) stays framework-free — no JSON tags, no template helpers, no queue versioning concerns.
- **`repository` ships as interfaces + hand-written mocks only** — no concrete DB, no `sqlc`/migration tool wired in. Real implementation is a documented plug-in point (`docs/plugging-in-a-database.md`), decided per project.
- **Generic `queue.Queue` interface**, with `sqs` and `servicebus` as swappable implementations selected by config — never import a queue SDK above `internal/queue`.
- **Transactions via `repository.Transactor`** (`WithinTx(ctx, fn)`), general-purpose — used for any multi-write operation, not just outbox (e.g. "create user + write audit log" uses the same shape).
- **Outbox pattern for anything that must reach a queue atomically with a DB write:** write the business row and an `OutboxRepository` row in the same `Transactor.WithinTx` call; a separate `cmd/outbox-relay` binary polls and publishes. Never call `queue.Enqueue` directly from a service that also writes to the DB in the same operation.
- **Every queue consumer must be idempotent** — at-least-once delivery is the guarantee, not exactly-once. Every consumer needs a stable message ID and a side effect safe to apply twice (upsert, dedup check). This is a code-review rule, not something the type system enforces.
- **Manual constructor injection** in each `main.go` — no DI framework (`wire`, etc.). Explicit, top-to-bottom, grep-able.
- **stdlib-only testing** — `t.Errorf`, table-driven tests, no `testify`. Interface + hand-written function-field mocks are the seam for every external dependency; no testcontainers.
- **Env vars only for config** — no SSM/Key Vault calls in app code; the deploy platform injects values.
- **`net/http` + `chi` + `html/template`** for HTTP/UI — no alternate router or `templ`.
- **`swaggo/swag`** generates OpenAPI from handler comments — not spec-first.
- **`slog` + OpenTelemetry, correlated.** A custom `slog.Handler` pulls `trace_id`/`span_id` from the span context on every log call — every handler/consumer must use the `*Context` `slog` variants (`InfoContext`, etc.) or correlation silently breaks. Traces/metrics export via **OTLP to a generic collector**, never a cloud-specific exporter baked into app code.
- **Tailwind via the standalone CLI**, no Node/npm anywhere in the build.

## Repo layout (quick reference)

```
cmd/
  api/{main.go, Dockerfile, handler/}
  ui/{main.go, Dockerfile, handler/, tailwind/}
  worker/{main.go, Dockerfile, consumer/}
  outbox-relay/{main.go, Dockerfile}
internal/
  config/ log/ otel/ httpserver/ queue/ domain/ service/ repository/ render/ version/
api/docs/           # swag output
web/templates/ web/static/
docs/plugging-in-a-database.md
docker-compose.yml  # local dev incl. otel-collector
Makefile
go.mod
```

## When applying this skill

1. **Scaffolding a new repo from scratch** — read `references/architecture.md` in full, then generate the file tree following its code samples (config loader, slog/otel handler, chi router, repository interfaces + mocks, service layer, queue interface, outbox + relay, Dockerfiles, `main.go` wiring for each binary).
2. **Adding a new binary to an existing repo built on this template** (a new worker, a cron job) — create a new `cmd/<name>/` with its own `main.go`, `Dockerfile`, and edge-type package; wire it to existing `internal/service` constructors rather than duplicating business logic.
3. **Adding a new domain/entity** (e.g. `Order` alongside `User`) — mirror the existing `User` pattern: `domain.Order`, `repository.OrderRepository` (+ mock), `service.OrderService` (+ mock), then per-binary edge types (`CreateOrderRequest`, `OrderViewModel`, `CreateOrderParam`) as needed.
4. **Reviewing/critiquing an existing Go service against this architecture** — check for the failure modes this template guards against: direct `repository`/`queue` calls from handlers (should go through `service`), non-atomic DB-write-then-enqueue sequences (should use `Transactor` + outbox), non-idempotent consumers, `slog` calls without context (breaks trace correlation), config read from anywhere but env vars.

For any implementation detail — exact interface signatures, full code for the outbox relay, the multi-stage Tailwind Dockerfile, the `Transactor` mock, wiring examples per binary — consult `references/architecture.md`, which is the authoritative source this skill is built from.
