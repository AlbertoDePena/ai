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
│   ├── log/             # slog setup: stdout JSON + otelslog bridge (fan-out)
│   ├── otel/             # tracer/meter provider setup, OTLP exporters
│   ├── httpserver/      # chi router, middleware, graceful shutdown
│   ├── queue/           # generic queue interface + sqs/servicebus impls
│   ├── domain/          # core types and business logic (no framework deps)
│   ├── service/         # business logic orchestration, shared across cmd/* binaries
│   ├── repository/      # concrete storage impls + mocks (interfaces declared by service, not here), incl. Transactor impl
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

- **`config`** — one `Load*()` function per binary reading env vars into a typed struct via small hand-rolled `os.Getenv` helpers (`getEnv` with a default, `mustEnv` for required). No struct tags, no reflection, no third-party env library. No file-based config, no cloud SDK calls.
- **`log`** — thin setup around `slog` bridged to OpenTelemetry via `otelslog` (`go.opentelemetry.io/contrib/bridges/otelslog`). The bridge emits each `slog` record as an OTel log record through the shared `LoggerProvider`, so `trace_id`/`span_id` are attached automatically from the active span — no custom `slog.Handler`. Logs then ride the same OTLP pipeline as traces and metrics.
- **`otel`** — sets up `TracerProvider`, `MeterProvider`, **and `LoggerProvider`**, each with an OTLP exporter (gRPC or HTTP, config-driven endpoint) and a single combined `shutdown(ctx)`; shared init code called from all `main.go` files. The `LoggerProvider` (registered globally) is what backs the `otelslog` bridge in `internal/log`.
- **`httpserver`** — chi router construction, common middleware (request ID, recover, timeout, the log-correlation middleware), and a graceful-shutdown helper (`http.Server` + signal handling) used by both `api` and `ui`.
- **`queue`** — the generic interface described below, plus `sqs` and `servicebus` implementations selected by config.
- **`domain`** — plain Go types, no `net/http`, no SQL, no queue types.
- **`service`** — business logic and orchestration, split into **entity services** (`UserService`, `OrderService` — one entity's own persistence/invariants) and **use-case services** (`RegisterUserService`, `CheckoutService` — orchestration across entities or external systems, depending on entity services, never the reverse). Each service file declares its own small, unexported interfaces for whatever it depends on (a repository, a `Transactor`, an email/billing client) — interfaces live with their consumer, not in `repository` or `domain`. This is the shared seam consumed by `cmd/api` HTTP handlers, `cmd/ui` template handlers, and any `cmd/<worker>` consumer or relay — see "Service layer" below.
- **`repository`** — concrete implementations only (e.g. `PostgresUserRepository`, `PostgresOutboxRepository`, a `Transactor` implementation), plus hand-written mocks scoped to whatever interface a given `service` file declares. No interface types live here, no `sqlc`, no driver import above this package. See `docs/plugging-in-a-database.md`.
- **`render`** — thin helpers around `html/template` (template set loading, layout composition, HTMX partial-response helpers). Named for the behavior (rendering), deliberately *not* `web`, so it never collides with the repo-root `web/` asset directory. This is Go code only; the template and static-asset *files* it renders live under repo-root `web/` (see the tree above).
- **`version`** — `var Version, Commit, BuildTime string` set via `-ldflags` at build time, exposed on a `/version` or `/healthz` style endpoint.

---

## Config: env vars only

Hand-rolled with the standard library only — two small helpers cover every binary's needs, no reflection and no struct tags to learn.

```go
// internal/config/env.go
package config

import "os"

// getEnv returns the value of key, or def when the var is unset or empty.
func getEnv(key, def string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return def
}

// mustEnv returns the value of key, or appends key to missing when unset.
// Collecting into a slice lets Load* report every missing var at once
// instead of failing on the first one.
func mustEnv(key string, missing *[]string) string {
    v := os.Getenv(key)
    if v == "" {
        *missing = append(*missing, key)
    }
    return v
}
```

```go
// internal/config/api.go
package config

import (
    "fmt"
    "strings"
)

type API struct {
    Port         string // PORT, default 8080
    LogLevel     string // LOG_LEVEL, default info
    OTELEndpoint string // OTEL_EXPORTER_OTLP_ENDPOINT, required
    QueueBackend string // QUEUE_BACKEND, default sqs (sqs | servicebus)
}

func LoadAPI() (API, error) {
    var missing []string
    c := API{
        Port:         getEnv("PORT", "8080"),
        LogLevel:     getEnv("LOG_LEVEL", "info"),
        OTELEndpoint: mustEnv("OTEL_EXPORTER_OTLP_ENDPOINT", &missing),
        QueueBackend: getEnv("QUEUE_BACKEND", "sqs"),
    }
    if len(missing) > 0 {
        return API{}, fmt.Errorf("missing required env vars: %s", strings.Join(missing, ", "))
    }
    return c, nil
}
```

For non-string values (ints, bools, durations) add a matching helper next to `getEnv` — e.g. `getEnvInt(key string, def int) (int, error)` wrapping `strconv.Atoi` — rather than reaching for a library. Keep the helper set minimal and grow it only when a binary actually needs the type.

No SSM/Key Vault calls in app code. Each platform's deploy tooling (ECS task definition, Azure Container App secrets) is responsible for injecting the actual values as env vars. If a future project needs a secrets backend, that's a config-loading swap, not an architecture change.

---

## Logging + OpenTelemetry correlation

Logging goes through the official slog→OTel bridge, `otelslog`, rather than a hand-rolled `slog.Handler`. The bridge emits each `slog` record as an OpenTelemetry log record via a shared `LoggerProvider`; because the OTel log SDK associates every record with the span in the `context.Context`, `trace_id`/`span_id` correlation is automatic and logs travel the same OTLP pipeline as traces and metrics — one collector, one wire format, correlated in the backend. It also sidesteps the classic custom-handler footgun where `WithAttrs`/`WithGroup` silently drop enrichment.

```go
// internal/otel/logs.go (traces/metrics set up alongside, sharing one resource + shutdown)
package otel

import (
    "context"

    "go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
    "go.opentelemetry.io/otel/log/global"
    sdklog "go.opentelemetry.io/otel/sdk/log"
    "go.opentelemetry.io/otel/sdk/resource"
)

func newLoggerProvider(ctx context.Context, res *resource.Resource) (*sdklog.LoggerProvider, error) {
    exp, err := otlploghttp.New(ctx) // endpoint from OTEL_EXPORTER_OTLP_ENDPOINT
    if err != nil {
        return nil, err
    }
    lp := sdklog.NewLoggerProvider(
        sdklog.WithResource(res),
        sdklog.WithProcessor(sdklog.NewBatchProcessor(exp)),
    )
    global.SetLoggerProvider(lp) // otelslog reads the global provider by default
    return lp, nil               // include lp.Shutdown in the combined shutdown(ctx)
}
```

```go
// internal/log/log.go
package log

import (
    "log/slog"
    "os"

    "go.opentelemetry.io/contrib/bridges/otelslog"
)

// New fans each record out to two sinks: a stdout JSON handler (so the
// platform's native log view — CloudWatch, Log Analytics — still shows
// lines) and the otelslog bridge, which emits through the global OTel
// LoggerProvider (set up in internal/otel) with trace context attached.
// Call this AFTER otel.Init, or the bridge binds to a no-op provider.
// (multiHandler is the small fan-out helper defined under "Stdout
// tradeoff" below — this two-sink setup is the template's default.)
func New(service string) *slog.Logger {
    return slog.New(multiHandler{
        slog.NewJSONHandler(os.Stdout, nil),
        otelslog.NewHandler(service),
    })
}
```

Every handler and worker function must still take `context.Context` and use the `*Context` slog variants (`slog.InfoContext(ctx, ...)`) — the bridge reads the span off that context, so a context-less log call loses correlation. This remains the one convention to enforce everywhere.

Traces, metrics, and now logs all export via OTLP to the collector endpoint (`OTEL_EXPORTER_OTLP_ENDPOINT`), wired once in `internal/otel` and started from each `main.go` with a single deferred `shutdown(ctx)` for a clean flush. Locally, `docker-compose.yml` runs an `otel/opentelemetry-collector` container so `make dev` gives working correlation across all three signals without a real cloud backend.

**Stdout tradeoff (matters for ECS/Fargate + Azure Container Apps).** On its own, `otelslog` sends logs to the collector, *not* to the process's stdout — so platform-native log views that tail container stdout (CloudWatch, Log Analytics) would be empty. That's exactly why `log.New` above fans out to a stdout `slog.JSONHandler` *and* the bridge: stdout capture is the default log path on these platforms, so the template pays for both by default. (The alternative — collector-only, with a `debug` exporter for local visibility — is fine if your platform doesn't rely on stdout; drop the JSON handler from `log.New` if so.) The fan-out helper:

```go
// internal/log/multi.go — fans one record out to N handlers; re-wraps on
// WithAttrs/WithGroup so enrichment survives slog.With(...) chaining.
type multiHandler []slog.Handler

func (m multiHandler) Enabled(ctx context.Context, l slog.Level) bool {
    for _, h := range m {
        if h.Enabled(ctx, l) {
            return true
        }
    }
    return false
}
func (m multiHandler) Handle(ctx context.Context, r slog.Record) error {
    for _, h := range m {
        if h.Enabled(ctx, r.Level) {
            if err := h.Handle(ctx, r.Clone()); err != nil {
                return err
            }
        }
    }
    return nil
}
func (m multiHandler) WithAttrs(a []slog.Attr) slog.Handler {
    out := make(multiHandler, len(m))
    for i, h := range m {
        out[i] = h.WithAttrs(a)
    }
    return out
}
func (m multiHandler) WithGroup(name string) slog.Handler {
    out := make(multiHandler, len(m))
    for i, h := range m {
        out[i] = h.WithGroup(name)
    }
    return out
}
```

One caveat with fan-out: the stdout `JSONHandler` copy won't carry `trace_id`/`span_id` — correlation is added by the OTel log SDK, which only sees the bridged copy. If you need trace IDs in the stdout copy too, wrap that `JSONHandler` in a tiny enrichment handler that pulls the span context off `ctx` (implementing `WithAttrs`/`WithGroup` to re-wrap, as above), and leave the bridge untouched.

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

**Testing payoff:** each handler/consumer test needs only its own local mock (e.g. `mockUserGetter`, declared next to the interface it satisfies) and asserts on its own edge type's shape — API tests check JSON, UI tests check the viewmodel fields the template needs, worker tests check param parsing — without any of them needing to know about the others' concerns.

---

## Repository: concrete implementations, consumer-owned interfaces

Interfaces are declared by whoever *calls* a dependency — not by the package that implements it, and not by `domain`, the package the interface is about. So `internal/repository` exports **no interface types**, only concrete implementations; `internal/service` declares the (usually small, unexported) interface it needs, and the concrete repository type satisfies it structurally with no explicit binding required:

```go
// internal/service/user.go
package service

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

// userRepository is declared here, next to its only caller — not in
// internal/repository and not in internal/domain.
type userRepository interface {
    GetByID(ctx context.Context, id string) (domain.User, error)
    Create(ctx context.Context, u domain.User) error
}
```

```go
// internal/repository/user.go
package repository

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

// PostgresUserRepository implements no interface of its own — it just has
// to structurally satisfy whatever a caller declares, e.g. service.userRepository above.
type PostgresUserRepository struct {
    // db *sql.DB, etc. — wired in once a database is chosen
}

func NewUserRepository() *PostgresUserRepository {
    return &PostgresUserRepository{}
}

func (r *PostgresUserRepository) GetByID(ctx context.Context, id string) (domain.User, error) {
    // ...
}

func (r *PostgresUserRepository) Create(ctx context.Context, u domain.User) error {
    // ...
}
```

```go
// internal/service/mock_user_test.go
package service

type mockUserRepository struct {
    GetByIDFunc func(ctx context.Context, id string) (domain.User, error)
    CreateFunc  func(ctx context.Context, u domain.User) error
}

func (m *mockUserRepository) GetByID(ctx context.Context, id string) (domain.User, error) {
    return m.GetByIDFunc(ctx, id)
}

func (m *mockUserRepository) Create(ctx context.Context, u domain.User) error {
    return m.CreateFunc(ctx, u)
}
```

Hand-written function-field mocks, not a generated-mock library — keeps the dependency list at zero and the mock file readable. Because the mock lives next to the interface it satisfies (in `service`, not `repository`), each consumer's mock only implements the methods that consumer actually declared — a different consumer with a narrower interface over the same `PostgresUserRepository` gets its own narrower mock, rather than every test depending on one repo-wide interface. `docs/plugging-in-a-database.md` documents how a real implementation (e.g. `sqlc` + `golang-migrate`, or anything else) slots into these concrete types.

---

## Transactions and the outbox pattern

Without a transaction boundary, a service like `CreateUser` that does `repo.Create` then `queue.Enqueue` as two separate calls has a gap: if the process crashes between them, or the enqueue fails after the DB write commits, the side effect (a welcome event, an audit log row, whatever) is silently lost. Fixing this needs two pieces: a general **transaction abstraction**, and — for anything that must eventually reach a queue — the **outbox pattern** built on top of it.

### `Transactor`: a general-purpose unit-of-work interface

Since `repository` exports concrete types only, the transaction boundary follows the same rule as everything else: the interface belongs to whichever `service` needs it, not to `repository`. The concrete implementation doesn't leak a driver type (`*sql.Tx`, etc.) above `repository` — services just get a closure that runs atomically:

```go
// internal/service/tx.go
package service

import "context"

// transactor is declared here because service is the consumer —
// internal/repository has no Transactor interface of its own, only the
// concrete implementation below.
type transactor interface {
    WithinTx(ctx context.Context, fn func(ctx context.Context) error) error
}
```

```go
// internal/repository/tx.go
package repository

import "context"

// PostgresTransactor stashes the tx handle on ctx; repositories that check
// ctx for an active tx use it, otherwise they fall back to a plain
// connection. Callers never see a tx object directly. Satisfies
// service.transactor structurally.
type PostgresTransactor struct {
    // db *sql.DB
}

func NewTransactor() *PostgresTransactor {
    return &PostgresTransactor{}
}

func (t *PostgresTransactor) WithinTx(ctx context.Context, fn func(ctx context.Context) error) error {
    // ...
}
```

```go
// internal/service/mock_tx_test.go
package service

type mockTransactor struct{}

func (mockTransactor) WithinTx(ctx context.Context, fn func(ctx context.Context) error) error {
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

`mockTransactor` just runs the closure, so service tests exercise real orchestration logic — including "if the second write fails, does the whole thing roll back and return the error" — without a real database.

### Outbox: one application of `Transactor`

Outbox swaps the second write for an `OutboxRepository.Insert` instead of a domain-specific table. The outbox row exists to be relayed to the real queue and then marked sent — not to be a permanent record:

```go
// internal/service/outbox.go
package service

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

// outboxWriter is all userService needs — just the atomic write side.
type outboxWriter interface {
    Insert(ctx context.Context, event domain.OutboxEvent) error
}
```

```go
// internal/repository/outbox.go
package repository

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

// PostgresOutboxRepository is the single concrete type. It exposes every
// method any consumer might need; each consumer (service.outboxWriter
// above, cmd/outbox-relay's own interface below) declares only the subset
// it actually uses.
type PostgresOutboxRepository struct {
    // db *sql.DB
}

func NewOutboxRepository() *PostgresOutboxRepository {
    return &PostgresOutboxRepository{}
}

func (r *PostgresOutboxRepository) Insert(ctx context.Context, event domain.OutboxEvent) error {
    // ...
}

func (r *PostgresOutboxRepository) FetchUnpublished(ctx context.Context, limit int) ([]domain.OutboxEvent, error) {
    // ...
}

func (r *PostgresOutboxRepository) MarkPublished(ctx context.Context, id string) error {
    // ...
}
```

Neither consumer depends on methods it doesn't call, even though both are backed by the same `PostgresOutboxRepository` — `cmd/outbox-relay` declares its own narrower interface for the read/publish side below.

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
package main

import "context"

// outboxReader is this binary's own consumer-owned interface — narrower
// than PostgresOutboxRepository, since the relay never calls Insert.
type outboxReader interface {
    FetchUnpublished(ctx context.Context, limit int) ([]domain.OutboxEvent, error)
    MarkPublished(ctx context.Context, id string) error
}

func main() {
    cfg, err := config.LoadOutboxRelay()
    if err != nil {
        fmt.Fprintf(os.Stderr, "config: %v\n", err) // no logger yet; internal/log owns the name "log"
        os.Exit(1)
    }
    shutdownOTel := otel.Init(context.Background(), cfg.OTELEndpoint, "outbox-relay")
    defer shutdownOTel(context.Background())
    logger := log.New("outbox-relay") // after otel.Init: the bridge binds to the now-registered provider

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

## Service layer: entity services and use-case services (shared across api, ui, and any worker binary)

Handlers and consumers shouldn't talk to `repository`/`queue` directly — that couples every entrypoint's tests to persistence and messaging details, and duplicates orchestration logic if the same operation is needed from more than one binary (e.g. "create a user" reachable from an API endpoint, an admin form in the UI, and a batch-import worker).

`internal/service` sits between them, and splits into two kinds of service:

- **Entity services** (`UserService`, `OrderService`) own one entity's own invariants and persistence. A method belongs here if it changes only when that entity's own rules change: `GetUser`, `CreateUser`, `UpdateUser`. This is the default starting point for a new entity — see "Adding a new domain/entity" in `SKILL.md`.
- **Use-case services** (`RegisterUserService`, `CheckoutService`) own orchestration: a method that touches another entity's service, calls an external system (email, billing, a third-party API), or composes more than one entity service in a single operation. Promote a method out of an entity service into a use-case service the moment it stops being about persisting/validating that one entity and starts being about "what happens when X occurs."

**Dependency direction is one-way: use-case services depend on entity services, never the reverse.** An entity service (`UserService`) never imports or references a use-case service (`RegisterUserService`) — it has no idea one exists.

### Entity service

```go
// internal/service/user.go
package service

import (
    "context"
    "encoding/json"

    "yourorg/yourapp/internal/domain"
)

// userRepository, transactor, and outboxWriter are declared here (the
// consumer), not in internal/repository — see "Repository: concrete
// implementations, consumer-owned interfaces" above.
type userRepository interface {
    GetByID(ctx context.Context, id string) (domain.User, error)
    Create(ctx context.Context, u domain.User) error
}

type transactor interface {
    WithinTx(ctx context.Context, fn func(ctx context.Context) error) error
}

type outboxWriter interface {
    Insert(ctx context.Context, event domain.OutboxEvent) error
}

// UserService is exported as a concrete type, not an interface — see
// "Interfaces belong to the consumer, all the way up" below for why.
type UserService struct {
    repo   userRepository
    outbox outboxWriter
    tx     transactor
}

func NewUserService(repo userRepository, outbox outboxWriter, tx transactor) *UserService {
    return &UserService{repo: repo, outbox: outbox, tx: tx}
}

func (s *UserService) GetUser(ctx context.Context, id string) (domain.User, error) {
    return s.repo.GetByID(ctx, id)
}

func (s *UserService) CreateUser(ctx context.Context, u domain.User) error {
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
        // cmd/outbox-relay (see "Transactions and the outbox pattern" above).
        // This stays inside UserService because it's about User's own
        // persistence guarantee, not orchestration across other systems.
        return s.outbox.Insert(ctx, domain.OutboxEvent{Type: "user.created", Payload: payload})
    })
}
```

**Interfaces belong to the consumer, all the way up.** `UserService` is exported as a concrete `*UserService`, not a `UserService` interface — the interface a caller needs belongs in the caller's own package, sized to exactly what that caller uses:

```go
// cmd/api/handler/user.go
package handler

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

// userGetter is this handler's own interface — it only needs GetUser here,
// even though *service.UserService has more methods.
type userGetter interface {
    GetUser(ctx context.Context, id string) (domain.User, error)
}

type UserHandler struct {
    svc userGetter
}

func NewUserHandler(svc userGetter) *UserHandler {
    return &UserHandler{svc: svc}
}
```

```go
// cmd/api/handler/mock_user_test.go
package handler

type mockUserGetter struct {
    GetUserFunc func(ctx context.Context, id string) (domain.User, error)
}

func (m *mockUserGetter) GetUser(ctx context.Context, id string) (domain.User, error) {
    return m.GetUserFunc(ctx, id)
}
```

`*service.UserService` satisfies `handler.userGetter` structurally, with no explicit binding. A different handler that also needs `CreateUser` declares a slightly wider local interface; neither depends on one repo-wide `service.UserService` interface, and no mock lives in `internal/service` for this purpose — each mock lives next to the interface it satisfies, in the consuming package.

### Use-case service

`RegisterUserService` is a use case: creating a user is only part of "registering" — it also has to talk to billing, which `UserService` has no business knowing about.

```go
// internal/service/register_user.go
package service

import (
    "context"

    "yourorg/yourapp/internal/domain"
)

// billingClient is declared here too — this package is the consumer.
type billingClient interface {
    CreateCustomer(ctx context.Context, userID string) error
}

// RegisterUserService depends on the entity service directly (a concrete
// *UserService, not an interface — see the note above) plus its own narrow
// interface over billing. It never depends on repository or queue directly.
type RegisterUserService struct {
    users   *UserService
    billing billingClient
}

func NewRegisterUserService(users *UserService, billing billingClient) *RegisterUserService {
    return &RegisterUserService{users: users, billing: billing}
}

func (s *RegisterUserService) Register(ctx context.Context, u domain.User) error {
    if err := s.users.CreateUser(ctx, u); err != nil {
        return err
    }
    return s.billing.CreateCustomer(ctx, u.ID) // best-effort/compensate on failure, per project
}
```

`cmd/api/handler` for the registration endpoint declares its own local interface over `RegisterUserService` (a `Register(ctx, domain.User) error` shape), the same pattern as `userGetter` above — it never depends on `*service.UserService` directly for this flow, since bypassing the use-case would create a second path that skips billing.

**Reused across every binary** — each `main.go` builds its own `repo`/`outbox`/`tx`/`billing` implementations, wires them into the *same* `service.NewUserService` (and `service.NewRegisterUserService` where that binary needs it), and hands the resulting service to whatever entrypoint it needs:

- `cmd/api/main.go` → passes `*RegisterUserService` into the registration HTTP handler, `*UserService` into read-only handlers
- `cmd/ui/main.go` → passes the *same* `*UserService` into a handler that renders `html/template` / HTMX partials
- `cmd/worker/main.go` → passes `*UserService` into a queue consumer that calls `CreateUser` when processing a batch-import message — that path never needs billing, so it never constructs `RegisterUserService` at all

The business rule ("creating a user also enqueues a welcome event") lives in exactly one place regardless of which binary triggers it, and commits atomically with the user row via the outbox — `cmd/outbox-relay` is the only thing that ever touches `queue.Queue` for this event. The billing side effect for registration lives in exactly one place too (`RegisterUserService`), so `cmd/worker`'s batch-import path — which creates users without registering them for billing — simply never wires that service up. Each binary's own `main.go` still only imports the pieces it actually uses — `cmd/worker` never imports `chi` or `html/template`, and only `cmd/outbox-relay` imports the concrete queue implementation for this flow — because wiring happens once per binary, not once for the whole repo.

**Testing impact:** handler tests mock only the local interface they declared (`userGetter`, a registration interface, etc.) — no repo/outbox/tx/billing knowledge needed. Service tests for `UserService` use `mockTransactor`, `mockUserRepository`, and `mockOutboxWriter` (all declared in `internal/service`, per "Interfaces belong to the consumer") to verify orchestration — e.g. "if `Create` fails, `outbox.Insert` is never called and the transaction rolls back." Service tests for `RegisterUserService` wire a real `*UserService` to those same mocks plus a `mockBillingClient`, so the composition itself is exercised, not just each piece in isolation.

---

## Generic queue interface (worker)

`queue.Queue` is a deliberate exception to "interfaces live with the consumer": `sqs` and `servicebus` are two swappable *implementations* selected at runtime by config, not one specific caller's dependency, so the contract they both have to agree to is declared where they both live, not inside whichever `cmd/<worker>` happens to pick one:

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

`internal/queue/sqs` and `internal/queue/servicebus` each implement `Queue`. Selection happens in `cmd/worker/main.go` based on `QueueBackend` config — the worker's business logic never imports either SDK directly, and tests use a hand-written `mockQueue` (declared wherever a consumer needs it) the same way repository/service tests do. Every consumer built on this interface must be idempotent — see "Delivery guarantee: at-least-once" above.

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
            svc := &mockUserGetter{GetUserFunc: tt.mockGet} // declared in handler, satisfies handler.userGetter
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
        fmt.Fprintf(os.Stderr, "config: %v\n", err) // no logger yet; internal/log owns the name "log"
        os.Exit(1)
    }

    shutdownOTel := otel.Init(context.Background(), cfg.OTELEndpoint, "api")
    defer shutdownOTel(context.Background())
    logger := log.New("api") // after otel.Init: the bridge binds to the now-registered provider

    userRepo := repository.NewUserRepository()             // *PostgresUserRepository — wherever the real impl lives once plugged in
    outboxRepo := repository.NewOutboxRepository()          // *PostgresOutboxRepository
    tx := repository.NewTransactor()                        // *PostgresTransactor
    // Each concrete type above satisfies the smaller interface each service
    // package declared (service.userRepository, service.outboxWriter,
    // service.transactor) purely structurally — no explicit binding.
    userSvc := service.NewUserService(userRepo, outboxRepo, tx) // same constructor used by cmd/ui and cmd/worker
    billing := billingclient.New(cfg.BillingAPIKey)             // only cmd/api's registration flow needs this
    registerSvc := service.NewRegisterUserService(userSvc, billing)
    userHandler := handler.NewUserHandler(userSvc)              // logger comes from request context (LoggingMiddleware), not the constructor
    registerHandler := handler.NewRegisterHandler(registerSvc)

    r := httpserver.NewRouter(httpserver.LoggingMiddleware(logger))
    r.Get("/users/{id}", userHandler.GetUser)
    r.Post("/register", registerHandler.Register)

    httpserver.RunWithGracefulShutdown(r, cfg.Port, logger)
}
```

`cmd/ui/main.go` and `cmd/worker/main.go` follow the same pattern — build `repo`, `outboxRepo`, and `tx`, call the same `service.NewUserService`, then hand the result to that binary's own entrypoint (template handler, or queue consumer respectively). Neither wires `billingclient` or calls `service.NewRegisterUserService`, since neither binary's flows need the registration use case — wiring only what a binary actually uses is the whole point of doing this by hand instead of with a shared container. The HTTP binaries (`api`, `ui`) get graceful shutdown from `httpserver.RunWithGracefulShutdown`; the loop-based binaries (`worker`, `outbox-relay`) must build their own via `signal.NotifyContext` (see the relay above) — every binary honors SIGTERM so deploys don't kill in-flight work. `cmd/outbox-relay/main.go` is the exception — it wires `outboxRepo` and the concrete `queue.Queue` directly (see "Transactions and the outbox pattern" above), since relaying is its entire job rather than something reached through `service`. Everything explicit, top to bottom, grep-able. No `wire`, no reflection-based container.

---

## What's a documented plug-in point, not shipped code

- **Database / migrations** — concrete repository types and their mocks exist (including a `Transactor` and `OutboxRepository` implementation), with the interfaces they satisfy declared in `internal/service`; `sqlc`/`golang-migrate` (or anything else) gets wired in per-project. Documented in `docs/plugging-in-a-database.md`.
- **Queue backend concrete choice** — interface + both `sqs`/`servicebus` stubs exist; which one is active is a config flag, consumed by `cmd/outbox-relay` and any `cmd/<worker>` that publishes or consumes directly.

## What's intentionally left out for now

- No CI/CD pipeline files generated yet (GitHub Actions vs. Azure Pipelines wasn't settled)
- No linting config (`golangci-lint` config, `gofmt`/`goimports` enforcement) specified yet
- No `Makefile` targets defined yet beyond implied `build`/`test`/`swag`/`tailwind`

When scaffolding a repo, confirm with the user whether these should be generated in the first pass or deferred as follow-ups — don't invent a CI provider, linter config, or Makefile targets without asking, since each was left open deliberately.
