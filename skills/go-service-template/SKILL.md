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
- **Layering, strictly one direction:** entrypoint edge type → `service` → `repository`/`queue`/`Transactor` → (real DB/queue, plugged in later). Handlers and consumers never call `repository` or `queue` directly — always through `service`.
- **`domain` is data only.** `domain.User` (etc.) stays framework-free — no JSON tags, no template helpers, no queue versioning concerns, and **no interfaces**. Domain types describe entities, not behavior contracts.
- **Interfaces are owned by the consumer, not the implementer or the subject.** Don't define `UserRepository` inside `repository`, and don't define it inside `domain`. Instead, the package that *calls* the dependency declares the minimal interface it needs, typically unexported and often one or two methods:

  ```go
  // internal/service/user.go
  type userRepository interface {
      GetByID(ctx context.Context, id string) (domain.User, error)
      Save(ctx context.Context, u domain.User) error
  }

  type UserService struct {
      repo userRepository
  }
  ```

  `internal/repository` then exports only concrete implementations (`PostgresUserRepository`, etc.) with no interface declarations of its own. They satisfy consumer interfaces structurally — no explicit binding needed. Different consumers may declare different, narrower interfaces over the same concrete type; don't force every caller to depend on one fat shared interface.
- **Two-tier `service` layer: entity services and use-case services.**
  * **Entity services** (`UserService`, `OrderService`) own one entity's own invariants and persistence — CRUD-shaped methods that change only when that entity's own rules change (`GetUser`, `CreateUser`, `UpdateUser`, `ListUsersByOrg`). This is the default and the right place to start for a new entity.
  * **Use-case services** (`RegisterUserService`, `CheckoutService`) own orchestration — a method that touches another entity's service, calls an external system (email, billing, a third-party API), or composes multiple entity services in one operation. Promote a use case out of an entity service the moment a method stops being about persisting/validating that entity and starts being about "what happens when X occurs."
  * **Dependency direction is one-way: use-case services depend on entity services, never the reverse.** `RegisterUserService` holds a `*UserService` (plus `emailSender`, `billingClient`, etc., each a consumer-owned interface); `UserService` never references `RegisterUserService` or knows it exists.
  * Handlers/consumers call whichever is appropriate: simple reads/writes go straight to the entity service; anything with orchestration goes through the use-case service, never bypassing it to call the entity service directly (that creates two divergent paths to the same effect, e.g. "create user with welcome email" vs. "create user silently").
  * Don't default to one use-case-per-operation across the board — that proliferates fast in a multi-binary repo where each `cmd/` may want slightly different orchestration. Keep binary-specific glue in that binary's handler/consumer layer; only promote to a shared use-case service when the orchestration itself is reused across binaries or entities.
- **`repository` ships as concrete implementations + hand-written mocks only** — no `sqlc`/migration tool wired in. Real implementation is a documented plug-in point (`docs/plugging-in-a-database.md`), decided per project. Mocks satisfy whatever consumer interface they're being tested against, not one repo-wide interface.
- **Generic `queue.Queue` consumer interface**, defined by whoever calls it, with `sqs` and `servicebus` as swappable implementations selected by config — never import a queue SDK above `internal/queue`.
- **Transactions via a consumer-defined `Transactor` interface** (`WithinTx(ctx, fn)`), general-purpose — used for any multi-write operation, not just outbox (e.g. "create user + write audit log" uses the same shape).
- **Outbox pattern for anything that must reach a queue atomically with a DB write:** write the business row and an outbox row in the same `Transactor.WithinTx` call; a separate `cmd/outbox-relay` binary polls and publishes. Never call `queue.Enqueue` directly from a service that also writes to the DB in the same operation.
- **Every queue consumer must be idempotent** — at-least-once delivery is the guarantee, not exactly-once. Every consumer needs a stable message ID and a side effect safe to apply twice (upsert, dedup check). This is a code-review rule, not something the type system enforces.
- **Manual constructor injection** in each `main.go` — no DI framework (`wire`, etc.). Explicit, top-to-bottom, grep-able. Each binary constructs its own entity services and, if it needs them, its own use-case services, wiring concrete `repository`/`email`/`billing`/etc. implementations into whatever local interfaces each service package declared.
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

1. **Scaffolding a new repo from scratch** — read `references/architecture.md` in full, then generate the file tree following its code samples (config loader, slog/otel handler, chi router, repository implementations, consumer-owned interfaces, entity + use-case services, queue implementations, outbox + relay, Dockerfiles, `main.go` wiring for each binary).
2. **Adding a new binary to an existing repo built on this template** (a new worker, a cron job) — create a new `cmd/<name>/` with its own `main.go`, `Dockerfile`, and edge-type package; wire it to existing entity/use-case service constructors rather than duplicating business logic.
3. **Adding a new domain/entity** (e.g. `Order` alongside `User`) — mirror the existing `User` pattern: `domain.Order` (data only), a concrete `repository.PostgresOrderRepository` (+ mock), a `service.OrderService` entity service declaring its own `orderRepository` interface, then per-binary edge types (`CreateOrderRequest`, `OrderViewModel`, `CreateOrderParam`) as needed. Only add an `OrderService`-adjacent use-case service (e.g. `CheckoutService`) once an operation needs orchestration beyond `Order`'s own persistence.
4. **Reviewing/critiquing an existing Go service against this architecture** — check for the failure modes this template guards against: direct `repository`/`queue` calls from handlers (should go through `service`), non-atomic DB-write-then-enqueue sequences (should use `Transactor` + outbox), non-idempotent consumers, `slog` calls without context (breaks trace correlation), config read from anywhere but env vars, interfaces declared in `domain` or in `repository` instead of by the consumer, and entity services that have quietly absorbed orchestration logic (external API calls, cross-entity composition) that belongs in a use-case service instead.

For any implementation detail — exact interface signatures, full code for the outbox relay, the multi-stage Tailwind Dockerfile, the `Transactor` mock, wiring examples per binary — consult `references/architecture.md`, which is the authoritative source this skill is built from.
