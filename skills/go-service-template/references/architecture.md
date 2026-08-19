# Go Multi-Binary Template — Architecture

## Goals

> **Reading the code samples below:** they are illustrative and occasionally trim imports and struct fields for space, but they do **not** trim error handling — every generated `.go` file must check and handle every returned `error` (no `_ :=` on a call that can fail, no bare `json.Unmarshal(...)`). Treat the samples as the minimum bar, not a license to drop error checks.

One repository that can produce any number of independently deployable services — an **API**, an **SSR UI**, and any number of **background binaries** (queue consumers, an outbox relay, cron-style jobs, batch imports, etc.) — sharing a single `internal/` library, built for containerized deployment. Each binary is its own container, its own deploy, its own failure domain, and — crucially for background work — its own scaling policy. "Worker" is not one binary; it's a category. A queue consumer that needs 10 replicas under load and an outbox relay that must run as exactly 1 replica are both "workers," but they scale, deploy, and fail independently, so they get separate `cmd/` entries rather than sharing one. Decisions below favor portability (env-var config, OTLP export, standard library first) and testability (interface-based mocking, no test framework dependency) over convenience shortcuts.

---

## Repository layout

```
.
├── cmd/
│   ├── api/
│   │   ├── main.go
│   │   ├── Dockerfile
│   │   └── handler/         # CreateUserRequest, UserResponse, handler funcs
│   ├── ui/
│   │   ├── main.go
│   │   ├── Dockerfile
│   │   ├── handler/         # UserViewModel, handler funcs
│   │   └── tailwind/
│   │       ├── input.css
│   │       └── tailwind.config.js
│   ├── worker/
│   │   ├── main.go
│   │   ├── Dockerfile
│   │   └── consumer/        # CreateUserParam, consumer funcs
│   └── outbox-relay/        # separate binary: polls outbox table, publishes to queue.Queue
│       ├── main.go          # runs as a single replica (or with claim-locking) — different
│       └── Dockerfile       # scaling profile than worker, so it's its own binary, not a
│                            # second loop inside worker
├── internal/
│   ├── config/          # env var loading, per-binary config structs
│   ├── log/             # slog setup + otel correlation handler
│   ├── otel/             # tracer/meter provider setup, OTLP exporters
│   ├── httpserver/      # chi router, middleware, graceful shutdown
│   ├── queue/           # generic queue interface + sqs/servicebus impls
│   ├── domain/          # core types and business logic (no framework deps)
│   ├── service/         # business logic orchestration, shared across cmd/* binaries
│   ├── repository/      # storage interfaces + mocks (no concrete impl), incl. Transactor
│   ├── render/          # html/template RENDERING HELPERS (Go code) — not the templates themselves
│   └── version/         # build-time version/commit injection
├── api/
│   └── docs/            # swag-generated OpenAPI output
├── web/                 # ASSET ROOT: the actual template/static files (rendered by internal/render)
│   ├── templates/       # html/template files (layouts, partials, pages)
│   └── static/          # compiled Tailwind CSS, JS, images
├── docs/
│   └── plugging-in-a-database.md
├── docker-compose.yml   # local dev: otel-collector, app binaries
├── Makefile
└── go.mod
```

One `go.mod` for the whole repo. Every `cmd/*` binary imports from `internal/` directly — no per-binary module boundaries, no version bumping between "packages." Adding a new background binary (another queue consumer, a cron job, a batch importer) means adding another `cmd/<name>/` directory with its own `main.go` and `Dockerfile` — never adding a run-mode flag to an existing binary.

---

## `internal/` package responsibilities

Kept flat and organic rather than pre-split into a rigid layering scheme. Add a subpackage when a concern earns one; don't create empty ones speculatively.

- **`config`** — one `Load[T]()`-style function per binary reading env vars into a typed struct, with `required`/`default` tags or explicit validation. No file-based config, no cloud SDK calls.
- **`log`** — wraps `slog` with a custom `Handler` that reads `trace_id`/`span_id` off the `context.Context` (via OTel's span context) and attaches them as structured fields, so every log line correlates to a trace.
- **`otel`** — sets up `TracerProvider` and `MeterProvider` with an OTLP exporter (gRPC or HTTP, config-driven endpoint), shared init code called from all three `main.go` files.
- **`httpserver`** — chi router construction, common middleware (request ID, recover, timeout, the log-correlation middleware), and a graceful-shutdown helper (`http.Server` + signal handling) used by both `api` and `ui`.
- **`queue`** — the generic interface described below, plus `sqs` and `servicebus` implementations selected by config.
- **`domain`** — plain Go types, no `net/http`, no SQL, no queue types.
- **`service`** — business logic and orchestration (e.g. "create user, then enqueue a welcome event"). Depends on `repository` and `queue` interfaces, exposes its own interface. This is the shared seam consumed by `cmd/api` HTTP handlers, `cmd/ui` template handlers, and any `cmd/<worker>` consumer or relay — see "Service layer" below.
- **`repository`** — interfaces only (e.g. `UserRepository`, `OutboxRepository`, `Transactor`), plus generated/hand-written mocks. No `sqlc`, no driver import. See `docs/plugging-in-a-database.md`.
- **`render`** — thin helpers around `html/template` (template set loading, layout composition, HTMX partial-response helpers). Named for the behavior (rendering), deliberately *not* `web`, so it never collides with the repo-root `web/` asset directory. This is Go code only; the template and static-asset *files* it renders live under repo-root `web/` (see the tree above).
- **`version`** — `var Version, Commit, BuildTime string` set via `-ldflags` at build time, exposed on a `/version` or `/healthz` style endpoint.

---

## Config: env vars only

```go
// internal/config/api.go
package config

import "github.com/caarlos0/env/v9" // or hand-rolled os.Getenv — pick one and stay consistent

type API struct {
    Port           string `env:"PORT" envDefault:"8080"`
    LogLevel       string `env:"LOG_LEVEL" envDefault:"info"`
    OTELEndpoint   string `env:"OTEL_EXPORTER_OTLP_ENDPOINT,required"`
    QueueBackend   string `env:"QUEUE_BACKEND" envDefault:"sqs"` // sqs | servicebus
}

func LoadAPI() (API, error) {
    var c API
    if err := env.Parse(&c); err != nil {
        return API{}, err
    }
    return c, nil
}
```

No SSM/Key Vault calls in app code. Each platform's deploy tooling (ECS task definition, Azure Container App secrets) is responsible for injecting the actual values as env vars. If a future project needs a secrets backend, that's a config-loading swap, not an architecture change.

---

## Logging + OpenTelemetry correlation

The core trick is a custom `slog.Handler` that enriches every record with trace context:

```go
// internal/log/otel_handler.go
package log

import (
    "context"
    "log/slog"

    "go.opentelemetry.io/otel/trace"
)

type otelHandler struct {
    slog.Handler
}

func (h *otelHandler) Handle(ctx context.Context, r slog.Record) error {
    if span := trace.SpanFromContext(ctx); span.SpanContext().IsValid() {
        r.AddAttrs(
            slog.String("trace_id", span.SpanContext().TraceID().String()),
            slog.String("span_id", span.SpanContext().SpanID().String()),
        )
    }
    return h.Handler.Handle(ctx, r)
}

func New(base slog.Handler) *slog.Logger {
    return slog.New(&otelHandler{Handler: base})
}
```

Every handler and worker function must take `context.Context` and use `slog.InfoContext(ctx, ...)` (not the context-less variants) or the correlation never fires. This is the one convention that has to be enforced everywhere — worth a lint rule or code review checklist item.

Traces and metrics both export via OTLP to a collector endpoint (`OTEL_EXPORTER_OTLP_ENDPOINT`), set up once in `internal/otel` and called from each `main.go`. Locally, `docker-compose.yml` runs an `otel/opentelemetry-collector` container so `make dev` gives you working correlation without touching a real cloud backend.

---

## HTTP layer: chi + html/template

```go
// internal/httpserver/router.go
package httpserver

import (
    "net/http"
    "time"

    "github.com/go-chi/chi/v5"
    "github.com/go-chi/chi/v5/middleware"
)

func NewRouter(logMW func(http.Handler) http.Handler) *chi.Mux {
    r := chi.NewRouter()
    r.Use(middleware.RequestID)
    r.Use(middleware.Recoverer)
    r.Use(middleware.Timeout(30 * time.Second))
    r.Use(logMW) // injects trace-correlated *slog.Logger into request context
    return r
}
```

`cmd/api` mounts JSON handlers with `swag`-annotated comments above each one; `cmd/ui` mounts handlers that render `html/template` sets and return HTMX-friendly partials on `HX-Request` headers. Both share `NewRouter` and the graceful-shutdown helper in `internal/httpserver`.

```go
// example swag-annotated handler (cmd/api)

// GetUser godoc
// @Summary      Get a user by ID
// @Tags         users
// @Produce      json
// @Param        id   path      string  true  "User ID"
// @Success      200  {object}  domain.User
// @Failure      404  {object}  httpserver.ErrorResponse
// @Router       /users/{id} [get]
func (h *UserHandler) GetUser(w http.ResponseWriter, r *http.Request) {
    // ...
}
```

`swag init` generates `api/docs/` at build time (wired into the Makefile / CI, not committed).

---

## Entry-point types: Request/Response, ViewModel, Param

`domain.User` is the source of truth for business rules and stays free of JSON tags, HTML-escaping concerns, or queue-message versioning — those are properties of each entrypoint's edge, not the domain. Each binary defines and owns its own edge types, colocated with its handlers/consumers so nothing else in the repo can import them:

- **`cmd/api/handler`** — `Request`/`Response` structs, JSON-tagged, versioned independently of `domain.User` so the wire contract can change without touching the domain (or vice versa).
- **`cmd/ui/handler`** — `ViewModel` structs shaped for what `html/template` needs: pre-formatted dates, template-safe strings, boolean flags the template branches on (`IsOwner bool`) — things that would pollute `domain.User` if put there directly.
- **`cmd/worker/consumer`** — `Param`/`Input` structs matching the queue message's JSON body. Producers and consumers deploy independently, so this contract needs its own stability separate from the current domain shape.

```go
// cmd/api/handler/user.go
package handler

type CreateUserRequest struct {
    Name  string `json:"name"`
    Email string `json:"email"`
}

func (r CreateUserRequest) toDomain() domain.User {
    return domain.User{Name: r.Name, Email: r.Email}
}

type UserResponse struct {
    ID   string `json:"id"`
    Name string `json:"name"`
}

func fromDomain(u domain.User) UserResponse {
    return UserResponse{ID: u.ID, Name: u.Name}
}

func (h *UserHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
    var req CreateUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request body", http.StatusBadRequest)
        return
    }
    if err := h.svc.CreateUser(r.Context(), req.toDomain()); err != nil {
        http.Error(w, "could not create user", http.StatusInternalServerError)
        return
    }
    w.WriteHeader(http.StatusCreated) // service.CreateUser returns only error; no body to echo
}

func (h *UserHandler) GetUser(w http.ResponseWriter, r *http.Request) {
    u, err := h.svc.GetUser(r.Context(), chi.URLParam(r, "id"))
    if err != nil {
        http.Error(w, "not found", http.StatusNotFound)
        return
    }
    _ = json.NewEncoder(w).Encode(fromDomain(u)) // UserResponse is the api edge type
}
```

```go
// cmd/ui/handler/user.go
package handler

type UserViewModel struct {
    ID        string
    Name      string
    JoinedAgo string // pre-formatted for the template, e.g. "3 days ago"
}

func toViewModel(u domain.User) UserViewModel {
    return UserViewModel{ID: u.ID, Name: u.Name, JoinedAgo: humanize.Time(u.CreatedAt)}
}

func (h *UserHandler) ShowUser(w http.ResponseWriter, r *http.Request) {
    u, err := h.svc.GetUser(r.Context(), chi.URLParam(r, "id"))
    if err != nil {
        http.Error(w, "not found", http.StatusNotFound)
        return
    }
    render(w, "user_profile.html", toViewModel(u))
}
```

```go
// cmd/worker/consumer/user.go
package consumer

type CreateUserParam struct {
    Name  string `json:"name"`
    Email string `json:"email"`
}

func (p CreateUserParam) toDomain() domain.User {
    return domain.User{Name: p.Name, Email: p.Email}
}

func (c *UserConsumer) HandleMessage(ctx context.Context, msg queue.Message) error {
    var p CreateUserParam
    if err := json.Unmarshal(msg.Body, &p); err != nil {
        return err // a malformed body will never parse — return so it dead-letters, don't retry forever
    }
    return c.svc.CreateUser(ctx, p.toDomain())
}
```

Conversion is a method on the edge type (`req.toDomain()`), discoverable via autocomplete and kept next to the type it belongs to — rather than a separately centralized mapper package.

**Testing payoff:** each handler/consumer test needs only a `service.MockUserService` and asserts on its own edge type's shape — API tests check JSON, UI tests check the viewmodel fields the template needs, worker tests check param parsing — without any of them needing to know about the others' concerns.

---

## Repository interfaces (no concrete DB)

```go
// internal/repository/user.go
package repository

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

type UserRepository interface {
    GetByID(ctx context.Context, id string) (domain.User, error)
    Create(ctx context.Context, u domain.User) error
}
```

```go
// internal/repository/mock_user.go
package repository

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

type MockUserRepository struct {
    GetByIDFunc func(ctx context.Context, id string) (domain.User, error)
    CreateFunc  func(ctx context.Context, u domain.User) error
}

func (m *MockUserRepository) GetByID(ctx context.Context, id string) (domain.User, error) {
    return m.GetByIDFunc(ctx, id)
}

func (m *MockUserRepository) Create(ctx context.Context, u domain.User) error {
    return m.CreateFunc(ctx, u)
}
```

Hand-written function-field mocks, not a generated-mock library — keeps the dependency list at zero and the mock file readable. `docs/plugging-in-a-database.md` documents how a real implementation (e.g. `sqlc` + `golang-migrate`, or anything else) slots in behind these interfaces.

---

## Transactions and the outbox pattern

Without a transaction boundary, a service like `CreateUser` that does `repo.Create` then `queue.Enqueue` as two separate calls has a gap: if the process crashes between them, or the enqueue fails after the DB write commits, the side effect (a welcome event, an audit log row, whatever) is silently lost. Fixing this needs two pieces: a general **transaction abstraction**, and — for anything that must eventually reach a queue — the **outbox pattern** built on top of it.

### `Transactor`: a general-purpose unit-of-work interface

Since `repository` ships as interfaces only, the transaction boundary is an interface too. It doesn't leak a driver type (`*sql.Tx`, etc.) above `repository` — services just get a closure that runs atomically:

```go
// internal/repository/tx.go
package repository

import "context"

// Transactor runs fn within a single transaction. A concrete implementation
// stashes the tx handle on ctx; repositories that check ctx for an active
// tx use it, otherwise they fall back to a plain connection. Callers never
// see a tx object directly.
type Transactor interface {
    WithinTx(ctx context.Context, fn func(ctx context.Context) error) error
}
```

```go
// internal/repository/mock_tx.go
package repository

type MockTransactor struct{}

func (MockTransactor) WithinTx(ctx context.Context, fn func(ctx context.Context) error) error {
    return fn(ctx) // no real transaction in tests — just runs the closure
}
```

This is deliberately general — any service composing two or more repository writes atomically uses it, not just outbox. For example, "create a user and write an audit-log row" uses exactly the same shape:

```go
func (s *userService) CreateUser(ctx context.Context, u domain.User) error {
    return s.tx.WithinTx(ctx, func(ctx context.Context) error {
        if err := s.userRepo.Create(ctx, u); err != nil {
            return err
        }
        return s.auditRepo.Insert(ctx, domain.AuditEntry{Type: "user.created", UserID: u.ID})
    })
}
```

`MockTransactor` just runs the closure, so service tests exercise real orchestration logic — including "if the second write fails, does the whole thing roll back and return the error" — without a real database.

### Outbox: one application of `Transactor`

Outbox swaps the second write for an `OutboxRepository.Insert` instead of a domain-specific table. The outbox row exists to be relayed to the real queue and then marked sent — not to be a permanent record:

```go
// internal/repository/outbox.go
package repository

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

type OutboxRepository interface {
    Insert(ctx context.Context, event domain.OutboxEvent) error
    FetchUnpublished(ctx context.Context, limit int) ([]domain.OutboxEvent, error)
    MarkPublished(ctx context.Context, id string) error
}
```

```go
func (s *userService) CreateUser(ctx context.Context, u domain.User) error {
    return s.tx.WithinTx(ctx, func(ctx context.Context) error {
        if err := s.userRepo.Create(ctx, u); err != nil {
            return err
        }
        payload, err := json.Marshal(WelcomeEvent{UserID: u.ID})
        if err != nil {
            return err
        }
        return s.outboxRepo.Insert(ctx, domain.OutboxEvent{Type: "user.created", Payload: payload})
    })
}
```

The user row and the outbox row commit together or not at all. `CreateUser` no longer touches `queue.Queue` directly.

### `cmd/outbox-relay`: its own binary

A separate process polls `OutboxRepository.FetchUnpublished`, calls `queue.Enqueue` for each event, then `MarkPublished`. This is deliberately **not** a second loop inside `cmd/worker`: the relay has a different scaling profile than a queue consumer. A queue consumer usually wants N replicas under load; the relay should run as exactly one active instance (or use row-level claim locking) to avoid two replicas racing to publish — and double-publishing — the same outbox row. Bundling it into `cmd/worker` would force worker's replica count to satisfy the relay's constraint, or require adding claim-locking complexity just to allow N relays safely. As its own binary, `cmd/outbox-relay` gets its own ECS desired-count / Azure Container App replica setting (typically 1, or leader-elected later) with zero effect on how `cmd/worker` scales.

This is the same principle behind treating "worker" as a category rather than one binary: each independently-scalable background responsibility — a queue consumer, the outbox relay, a future cron job or batch importer — gets its own `cmd/<name>/` entry.

Even though the relay is a bare loop rather than an HTTP server, it still needs the two conventions the rest of the template enforces: **graceful shutdown** (ECS/Fargate and Azure Container Apps send SIGTERM on every deploy — a naked `for { … time.Sleep }` gets hard-killed mid-publish) and **context-correlated logging** (the `*Context` `slog` variants, so relay logs join the trace like everything else).

```go
// cmd/outbox-relay/main.go
func main() {
    cfg, err := config.LoadOutboxRelay()
    if err != nil {
        log.Fatal(err)
    }
    logger := log.New(slog.NewJSONHandler(os.Stdout, nil))
    shutdownOTel := otel.Init(context.Background(), cfg.OTELEndpoint, "outbox-relay")
    defer shutdownOTel(context.Background())

    // SIGTERM/SIGINT cancels ctx, so an in-flight poll finishes and the loop
    // exits cleanly on deploy instead of being killed mid-publish.
    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer stop()

    outboxRepo := repository.NewOutboxRepository() // plugged in once a DB is chosen
    q := queue.New(cfg.QueueBackend)

    ticker := time.NewTicker(cfg.PollInterval)
    defer ticker.Stop()
    for {
        events, err := outboxRepo.FetchUnpublished(ctx, 100)
        if err != nil {
            logger.ErrorContext(ctx, "relay fetch failed", "err", err)
        }
        for _, e := range events {
            if err := q.Enqueue(ctx, e.Payload); err != nil {
                logger.ErrorContext(ctx, "relay publish failed", "event_id", e.ID, "err", err)
                continue
            }
            if err := outboxRepo.MarkPublished(ctx, e.ID); err != nil {
                // Enqueue already succeeded; a failed mark means this event
                // republishes next poll — safe precisely because every
                // consumer is idempotent (see delivery guarantee above).
                logger.ErrorContext(ctx, "relay mark-published failed", "event_id", e.ID, "err", err)
            }
        }
        select {
        case <-ctx.Done():
            logger.InfoContext(ctx, "outbox relay shutting down")
            return
        case <-ticker.C:
        }
    }
}
```

### Delivery guarantee: at-least-once, so consumers must be idempotent

This outbox setup gives **at-least-once** delivery, not exactly-once. The relay can crash — or the process can be killed by the orchestrator — after `q.Enqueue` succeeds but before `outboxRepo.MarkPublished` commits. On the next poll, that event is still "unpublished" and gets enqueued again. The same gap exists on the consumer side of most real queues (SQS redelivery on a slow ack, Service Bus lock expiry) independent of outbox. There is no cheap way to upgrade this to exactly-once without a distributed transaction spanning the DB and the queue, which isn't worth the complexity for this template.

**Hard rule for this template: every queue consumer must be idempotent.** Concretely:

- Every message must carry a stable, unique identifier (the outbox event's ID, or a domain ID like the user ID for a `user.created` event) that the consumer can use to detect a message it has already processed.
- The consuming side effect must be safe to apply twice — e.g. `INSERT ... ON CONFLICT DO NOTHING`, an upsert, or checking a "processed message IDs" table/set before acting — rather than assuming an operation like "send welcome email" can run twice for free.
- This applies to **every** `cmd/<worker>` consumer added to the repo, not just the ones fed by the outbox relay — SQS and Service Bus both redeliver under normal operation, so the assumption holds regardless of where a message originated.

This is enforced by convention and code review, not by the type system — there's no way to make `Queue.Dequeue` refuse a non-idempotent handler. New consumers should treat "what happens if this message is delivered twice?" as a required question to answer before merging, the same way "what happens if `Create` fails?" is for a repository method.

---

## Service layer (shared across api, ui, and any worker binary)

Handlers and consumers shouldn't talk to `repository`/`queue` directly — that couples every entrypoint's tests to persistence and messaging details, and duplicates orchestration logic if the same operation is needed from more than one binary (e.g. "create a user" reachable from an API endpoint, an admin form in the UI, and a batch-import worker).

`internal/service` sits between them:

```go
// internal/service/user.go
package service

import (
    "context"
    "encoding/json"

    "yourorg/yourapp/internal/domain"
    "yourorg/yourapp/internal/repository"
)

type UserService interface {
    GetUser(ctx context.Context, id string) (domain.User, error)
    CreateUser(ctx context.Context, u domain.User) error
}

type userService struct {
    repo       repository.UserRepository
    outboxRepo repository.OutboxRepository
    tx         repository.Transactor
}

func NewUserService(repo repository.UserRepository, outboxRepo repository.OutboxRepository, tx repository.Transactor) UserService {
    return &userService{repo: repo, outboxRepo: outboxRepo, tx: tx}
}

func (s *userService) GetUser(ctx context.Context, id string) (domain.User, error) {
    return s.repo.GetByID(ctx, id)
}

func (s *userService) CreateUser(ctx context.Context, u domain.User) error {
    return s.tx.WithinTx(ctx, func(ctx context.Context) error {
        if err := s.repo.Create(ctx, u); err != nil {
            return err
        }
        payload, err := json.Marshal(WelcomeEvent{UserID: u.ID})
        if err != nil {
            return err
        }
        // business rule: new user triggers a welcome event — written atomically
        // with the user row via the outbox, then relayed to the real queue by
        // cmd/outbox-relay (see "Transactions and the outbox pattern" above)
        return s.outboxRepo.Insert(ctx, domain.OutboxEvent{Type: "user.created", Payload: payload})
    })
}
```

```go
// internal/service/mock_user.go
package service

type MockUserService struct {
    GetUserFunc    func(ctx context.Context, id string) (domain.User, error)
    CreateUserFunc func(ctx context.Context, u domain.User) error
}

func (m *MockUserService) GetUser(ctx context.Context, id string) (domain.User, error) {
    return m.GetUserFunc(ctx, id)
}

func (m *MockUserService) CreateUser(ctx context.Context, u domain.User) error {
    return m.CreateUserFunc(ctx, u)
}
```

**Dependency direction:** `handler`/`consumer` → `service` interface → `repository`/`Transactor` interfaces. Nothing above the service layer knows a database or queue exists — note `UserService` no longer depends on `queue.Queue` at all now that outbox owns the hand-off to the real queue.

**Reused across every binary** — each `main.go` builds its own `repo`/`outboxRepo`/`tx` implementations, wires them into the *same* `service.NewUserService`, and hands the resulting service to whatever entrypoint it needs:

- `cmd/api/main.go` → passes `UserService` into an HTTP handler that returns JSON
- `cmd/ui/main.go` → passes the *same* `UserService` into a handler that renders `html/template` / HTMX partials
- `cmd/worker/main.go` → passes it into a queue consumer that calls `CreateUser` when processing a batch-import message

The business rule ("creating a user also enqueues a welcome event") lives in exactly one place regardless of which binary triggers it, and now commits atomically with the user row via the outbox — `cmd/outbox-relay` is the only thing that ever touches `queue.Queue` for this event. Each binary's own `main.go` still only imports the pieces it actually uses — `cmd/worker` never imports `chi` or `html/template`, and only `cmd/outbox-relay` imports the concrete queue implementation for this flow — because wiring happens once per binary, not once for the whole repo.

**Testing impact:** handler tests mock `service.UserService` only (no repo/outbox/tx knowledge needed); service tests use `MockTransactor`, `MockUserRepository`, and `MockOutboxRepository` to verify orchestration (e.g. "if `Create` fails, `outboxRepo.Insert` is never called and the transaction rolls back").

---

## Generic queue interface (worker)

```go
// internal/queue/queue.go
package queue

import "context"

type Message struct {
    ID   string
    Body []byte
}

type Queue interface {
    Enqueue(ctx context.Context, body []byte) error
    Dequeue(ctx context.Context, max int) ([]Message, error)
    Ack(ctx context.Context, id string) error
}
```

`internal/queue/sqs` and `internal/queue/servicebus` each implement `Queue`. Selection happens in `cmd/worker/main.go` based on `QueueBackend` config — the worker's business logic never imports either SDK directly, and tests use a `MockQueue` the same way repository tests use `MockUserRepository`. Every consumer built on this interface must be idempotent — see "Delivery guarantee: at-least-once" above.

---

## Testing approach

- **stdlib `testing` only** — `t.Errorf`, table-driven tests, no `testify`.
- **Interface + hand-written mock** is the seam for every external dependency (repository, queue). No testcontainers, no real network calls in unit tests.
- Example pattern:

```go
// cmd/api/handler/user_test.go
func TestUserHandler_GetUser(t *testing.T) {
    tests := []struct {
        name       string
        mockGet    func(ctx context.Context, id string) (domain.User, error)
        wantStatus int
    }{
        {
            name: "found",
            mockGet: func(ctx context.Context, id string) (domain.User, error) {
                return domain.User{ID: id, Name: "Ada"}, nil
            },
            wantStatus: http.StatusOK,
        },
        {
            name: "not found",
            mockGet: func(ctx context.Context, id string) (domain.User, error) {
                return domain.User{}, domain.ErrNotFound
            },
            wantStatus: http.StatusNotFound,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            svc := &service.MockUserService{GetUserFunc: tt.mockGet}
            h := NewUserHandler(svc)

            req := httptest.NewRequest(http.MethodGet, "/users/abc", nil)
            rec := httptest.NewRecorder()
            h.GetUser(rec, req)

            if rec.Code != tt.wantStatus {
                t.Errorf("got status %d, want %d", rec.Code, tt.wantStatus)
            }
        })
    }
}
```

---

## Tailwind build (standalone CLI, no Node)

`cmd/ui/Dockerfile`, multi-stage:

```dockerfile
# --- tailwind stage ---
FROM alpine:3.20 AS tailwind
ARG TAILWIND_VERSION=v3.4.17   # pin explicitly — bump deliberately, never `latest` (breaks reproducible builds)
RUN apk add --no-cache curl
RUN curl -sLo /usr/local/bin/tailwindcss \
      https://github.com/tailwindlabs/tailwindcss/releases/download/${TAILWIND_VERSION}/tailwindcss-linux-x64 \
    && chmod +x /usr/local/bin/tailwindcss
WORKDIR /app
COPY cmd/ui/tailwind ./cmd/ui/tailwind
COPY web/templates ./web/templates
RUN tailwindcss -i ./cmd/ui/tailwind/input.css -o ./web/static/app.css --minify

# --- go build stage ---
FROM golang:1.23 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/ui ./cmd/ui

# --- final stage ---
FROM gcr.io/distroless/static-debian12
COPY --from=build /out/ui /ui
COPY --from=tailwind /app/web/static /web/static
COPY web/templates /web/templates
ENTRYPOINT ["/ui"]
```

`cmd/api`, `cmd/worker`, and `cmd/outbox-relay` use the same two-stage pattern minus the Tailwind stage — pure Go build, then distroless final image. Small images, no Node anywhere in the pipeline.

---

## Wiring (`main.go`, manual constructor injection)

```go
// cmd/api/main.go
func main() {
    cfg, err := config.LoadAPI()
    if err != nil {
        log.Fatal(err)
    }

    logger := log.New(slog.NewJSONHandler(os.Stdout, nil))
    shutdownOTel := otel.Init(context.Background(), cfg.OTELEndpoint, "api")
    defer shutdownOTel(context.Background())

    userRepo := repository.NewUserRepository()             // wherever the real impl lives once plugged in
    outboxRepo := repository.NewOutboxRepository()
    tx := repository.NewTransactor()
    userSvc := service.NewUserService(userRepo, outboxRepo, tx) // same constructor used by cmd/ui and cmd/worker
    userHandler := handler.NewUserHandler(userSvc, logger)

    r := httpserver.NewRouter(httpserver.LoggingMiddleware(logger))
    r.Get("/users/{id}", userHandler.GetUser)

    httpserver.RunWithGracefulShutdown(r, cfg.Port, logger)
}
```

`cmd/ui/main.go` and `cmd/worker/main.go` follow the same pattern — build `repo`, `outboxRepo`, and `tx`, call the same `service.NewUserService`, then hand the result to that binary's own entrypoint (template handler, or queue consumer respectively). The HTTP binaries (`api`, `ui`) get graceful shutdown from `httpserver.RunWithGracefulShutdown`; the loop-based binaries (`worker`, `outbox-relay`) must build their own via `signal.NotifyContext` (see the relay above) — every binary honors SIGTERM so deploys don't kill in-flight work. `cmd/outbox-relay/main.go` is the exception — it wires `outboxRepo` and the concrete `queue.Queue` directly (see "Transactions and the outbox pattern" above), since relaying is its entire job rather than something reached through `service`. Everything explicit, top to bottom, grep-able. No `wire`, no reflection-based container.

---

## What's a documented plug-in point, not shipped code

- **Database / migrations** — repository interfaces and mocks exist (including `Transactor` and `OutboxRepository`); `sqlc`/`golang-migrate` (or anything else) gets wired in per-project. Documented in `docs/plugging-in-a-database.md`.
- **Queue backend concrete choice** — interface + both `sqs`/`servicebus` stubs exist; which one is active is a config flag, consumed by `cmd/outbox-relay` and any `cmd/<worker>` that publishes or consumes directly.

## What's intentionally left out for now

- No CI/CD pipeline files generated yet (GitHub Actions vs. Azure Pipelines wasn't settled)
- No linting config (`golangci-lint` config, `gofmt`/`goimports` enforcement) specified yet
- No `Makefile` targets defined yet beyond implied `build`/`test`/`swag`/`tailwind`

When scaffolding a repo, confirm with the user whether these should be generated in the first pass or deferred as follow-ups — don't invent a CI provider, linter config, or Makefile targets without asking, since each was left open deliberately.
