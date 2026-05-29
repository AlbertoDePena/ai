# Go Hexagonal — Patterns, Anti-Patterns & Refactoring Recipes

## Table of Contents
1. [Core Patterns](#core-patterns)
2. [Anti-Patterns & Fixes](#anti-patterns--fixes)
3. [Refactoring Recipes](#refactoring-recipes)
4. [Testing Strategy](#testing-strategy)
5. [Common Go Pitfalls](#common-go-pitfalls)

---

## Core Patterns

### Pattern: Compile-time Interface Check
Always assert that adapters implement their ports. Put this at the top of the adapter file.
```go
var _ repository.OrderRepository = (*PostgresOrderRepository)(nil)

// Inside internal/core/usecase/create_order.go (same package):
// var _ CreateOrderUseCase = (*createOrderUseCase)(nil)
```
This causes a build error the moment the contract drifts — no runtime surprise.

### Pattern: Constructor returns the Interface, not the Struct
```go
// In internal/core/usecase/:
// CORRECT — caller only knows the port
func NewCreateOrderUseCase(repo repository.OrderRepository) CreateOrderUseCase {
    return &createOrderUseCase{orderRepo: repo}
}

// WRONG — exposes implementation detail
func NewCreateOrderUseCase(repo repository.OrderRepository) *createOrderUseCase {
    return &createOrderUseCase{orderRepo: repo}
}
```

### Pattern: DTO Translation at the Adapter Boundary
Adapters own translation. Domain objects never contain JSON tags or HTTP concepts.
```go
// dto/order_dto.go  (lives in adapter/http/dto/)
type CreateOrderRequest struct {
    CustomerID string            `json:"customer_id"`
    Items      []OrderItemReq    `json:"items"`
}

func (r CreateOrderRequest) ToParams() usecase.CreateOrderParams {
    // translate HTTP DTO → use case command
}

func OrderFromDomain(o *domain.Order) OrderResponse {
    // translate domain entity → HTTP DTO
}
```

### Pattern: Domain Errors, Adapter HTTP Status Mapping
```go
// adapter/http/handler/errors.go
func domainErrToHTTP(err error) int {
    switch {
    case errors.Is(err, domain.ErrOrderNotFound):
        return http.StatusNotFound
    case errors.Is(err, domain.ErrOrderAlreadyConfirmed):
        return http.StatusConflict
    default:
        return http.StatusInternalServerError
    }
}
```

### Pattern: Multiple Driven Adapters for One Port
The same driven port can have multiple implementations. Swap via `main.go`.
```go
// Both implement repository.OrderRepository
postgres.NewOrderRepository(db)
inmemory.NewOrderRepository()   // for tests
```

---

## Anti-Patterns & Fixes

### ❌ Anti-pattern: Importing infrastructure in core
```go
// internal/core/usecase/create_order.go — WRONG
import "database/sql"          // infra leak
import "github.com/gin-gonic/gin" // HTTP framework in core
```
**Fix:** For DB/infra leaks: define a driven port interface in `core/repository/` (or `core/bus/`, `core/mail/`, etc.); have the adapter implement it. For HTTP leaks: define the use case interface in `core/usecase/` and depend on that instead of the framework. Core only imports interfaces, never concrete infra.

---

### ❌ Anti-pattern: Fat use case that calls the DB directly
```go
func (uc *createOrderUseCase) Execute(ctx context.Context, cmd ...) {
    db.ExecContext(ctx, "INSERT INTO orders ...")  // WRONG
}
```
**Fix:** Inject `repository.OrderRepository`; call `uc.orderRepo.Save(...)`.

---

### ❌ Anti-pattern: Domain entity with JSON/DB tags
```go
// internal/core/domain/order.go — WRONG
type Order struct {
    ID     string `json:"id" db:"id" gorm:"primaryKey"`
}
```
**Fix:** Remove all tags from domain structs. Add tags only to DTO/model structs inside the adapter packages.

---

### ❌ Anti-pattern: Handler directly instantiating the use case
```go
// handler/order_handler.go — WRONG
func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
    uc := usecase.NewCreateOrderUseCase(postgres.NewOrderRepository(db))
    ...
}
```
**Fix:** Inject the driving port via the constructor. Wiring belongs only in `main.go`.

---

### ❌ Anti-pattern: Returning concrete adapter types from use cases
```go
// WRONG — use case returns a Postgres-specific type
func (uc *createOrderUseCase) Execute(...) (*postgres.OrderRow, error)
```
**Fix:** Always return domain types (`*domain.Order`) from use cases.

---

### ❌ Anti-pattern: Shared mutable global state in core
```go
// WRONG
var DB *sql.DB  // global in a core package
```
**Fix:** Pass dependencies explicitly via constructors.

---

### ❌ Anti-pattern: Business logic in the HTTP handler
```go
func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
    if order.Items == nil { // business rule — WRONG place
        http.Error(w, "items required", 400)
        return
    }
}
```
**Fix:** Move the rule into the domain entity or use case. The handler only validates that the HTTP payload is well-formed.

---

## Refactoring Recipes

### Recipe: Migrate a "service" package to hexagonal

**Before (common flat layout):**
```
internal/
  service/
    order_service.go      # has DB calls, business logic, HTTP response building
  repository/
    order_repo.go         # concrete struct, no interface
  handler/
    order_handler.go      # calls service, also does some business logic
```

**Step-by-step:**

1. **Extract domain entities** → move pure structs + business methods to `internal/core/domain/`.
2. **Define driven ports** → create `internal/core/repository/order.go` (and `core/bus/`, `core/mail/` etc. as needed); copy the method signatures from the concrete repo.
3. **Define driving ports** → create the use case interface alongside its implementation in `internal/core/usecase/`; export the interface, keep the struct unexported.
4. **Refactor service → use case** → move to `internal/core/usecase/`; replace concrete repo with the driven port interface; strip any HTTP/DB imports.
5. **Refactor repo → adapter** → move to `internal/adapter/postgres/`; add compile-time check; ensure it returns domain types (add mapping if needed).
6. **Refactor handler → adapter** → move to `internal/adapter/http/handler/`; extract DTOs to `dto/`; inject use case interface.
7. **Wire in `main.go`** → construct adapters, inject into use cases, inject use cases into handlers.
8. **Delete the old packages** once all references are updated.

---

### Recipe: Add a new feature end-to-end

Follow this order to respect the dependency rule:

```
1. domain/       — add or extend entity/value object/error
2. repository/   — define any new driven port interface needed
3. usecase/      — define the driving port interface + implement the use case
4. adapter/{postgres,kafka,...}/ — implement the new driven port method
5. adapter/{http,grpc,kafka,...}/ — add handler/consumer/etc.
6. cmd/main.go   — wire if new dependencies introduced

Note: A dual-role adapter (e.g. kafka) appears in both step 4 (producer)
and step 5 (consumer), but it's the same package — just different files.
```

---

### Recipe: Replace a driven adapter (e.g., swap MySQL → Postgres)

1. Ensure the driven port interface is already in `core/repository/` (or `core/bus/`, etc.).
2. Create `internal/adapter/postgres/<entity>_repository.go` implementing the port.
3. Add compile-time check: `var _ repository.XRepository = (*PostgresXRepository)(nil)`.
4. In `main.go`, swap `mysql.NewXRepository(db)` → `postgres.NewXRepository(db)`.
5. Delete the old adapter package.

Core and use cases are untouched.

---

## Testing Strategy

### Unit-test use cases with mock driven ports
```go
// usecase/create_order_test.go
type mockOrderRepo struct {
    saved *domain.Order
}
func (m *mockOrderRepo) Save(_ context.Context, o *domain.Order) error {
    m.saved = o
    return nil
}
func (m *mockOrderRepo) FindByID(_ context.Context, _ string) (*domain.Order, error) {
    return nil, domain.ErrOrderNotFound
}

func TestCreateOrder(t *testing.T) {
    repo := &mockOrderRepo{}
    uc   := usecase.NewCreateOrderUseCase(repo)
    order, err := uc.Execute(context.Background(), usecase.CreateOrderParams{
        CustomerID: "cust-1",
    })
    require.NoError(t, err)
    assert.Equal(t, "cust-1", repo.saved.CustomerID)
}
```
No database, no HTTP — pure Go. Fast and isolated.

### Integration-test driven adapters against a real DB
```go
// adapter/postgres/order_repository_test.go
// Spin up via testcontainers-go or a docker-compose fixture.
// Test Save + FindByID round-trips against a real Postgres instance.
```

### End-to-end test driving adapters via HTTP
```go
// adapter/http/handler/order_handler_test.go
// Use httptest.NewRecorder + inject mock use case (driving port).
// Tests HTTP wiring only — not business logic.
```

---

## Common Go Pitfalls in Hexagonal

| Pitfall | Solution |
|---------|----------|
| Interface in the wrong package | Driving ports live in `core/usecase/` alongside their implementation; driven ports live in `core/repository/`, `core/bus/`, etc. |
| Circular import between `usecase` and `adapter` | Core must never import adapter; if you feel the pull, you have a layering mistake |
| `context.Background()` in use cases | Always thread `context.Context` through; never create a new root context in core |
| Embedding framework types in domain | Never embed `gin.Context`, `http.Request`, `gorm.Model` in domain structs |
| Using `interface{}` / `any` across layer boundaries | Use typed DTOs and domain objects; `any` is a code smell at layer boundaries |
| One giant port with 20 methods | Split by use-case cohesion; prefer narrow, focused interfaces (Interface Segregation) |
