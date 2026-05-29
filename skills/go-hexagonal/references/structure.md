# Go Hexagonal — Canonical Folder Structure

## Full Layout

```
<project-root>/
├── cmd/
│   └── <app-name>/
│       └── main.go                  # Wiring only: construct adapters, inject into use cases, start server
│
├── internal/
│   ├── core/
│   │   ├── domain/
│   │   │   ├── <entity>.go          # Domain entity (struct + methods)
│   │   │   ├── <value_object>.go    # Value objects (immutable structs)
│   │   │   └── error.go             # Domain-specific error types
│   │   │
│   │   ├── usecase/                 # Driving ports + implementations
│   │   │   ├── create_order.go      # CreateOrderUseCase interface + createOrderUseCase struct
│   │   │   └── get_order.go         # GetOrderUseCase interface + getOrderUseCase struct
│   │   │
│   │   ├── repository/              # Driven ports (interfaces — pure contracts)
│   │   │   └── order.go             # OrderRepository interface
│   │   │
│   │   ├── bus/                     # Driven ports (event publishers)
│   │   │   └── order.go             # OrderEventPublisher interface
│   │   │
│   │   └── mail/                    # Driven ports (email senders)
│   │       └── sender.go            # EmailSender interface
│   │
│   ├── adapter/                      # One directory per technology
│   │   ├── http/                     # Driving — calls usecases
│   │   │   ├── handler/
│   │   │   │   └── <resource>_handler.go
│   │   │   ├── middleware/
│   │   │   ├── dto/
│   │   │   │   └── <resource>_dto.go   # HTTP-layer request/response structs
│   │   │   └── server.go
│   │   ├── grpc/                     # Driving — calls usecases
│   │   │   ├── handler/
│   │   │   └── proto/
│   │   ├── postgres/                 # Driven — implements repository.OrderRepository
│   │   │   └── order_repository.go
│   │   ├── redis/                    # Driven — implements cache interface
│   │   │   └── order_cache.go
│   │   ├── kafka/                    # Dual-role: consumer (driving) + producer (driven)
│   │   │   ├── consumer.go           #   calls usecases
│   │   │   └── producer.go           #   implements bus.OrderEventPublisher
│   │   └── sendgrid/                 # Driven — implements mail.EmailSender
│   │       └── sender.go
│   │
│   └── config/
│       └── config.go                # Config struct + loader (env vars, files) — no core imports
│
├── pkg/                             # Exported, reusable helpers (no business logic, no core imports)
│   └── <util>/
│
├── migrations/                      # SQL / migration files
├── docker-compose.yml
├── Makefile
└── go.mod
```

---

## Naming Conventions

| Artifact | Convention | Example |
|----------|-----------|---------|
| Driving port (use case interface) | `<Verb><Noun>UseCase` interface | `CreateOrderUseCase` |
| Use case struct | `<verb><Noun>UseCase` (lowercase, unexported) + constructor returning the interface | `createOrderUseCase` |
| Use case params | `<Verb><Noun>Params` struct inside the use case file | `CreateOrderParams` |
| Driven port | `<Noun>Repository`, `<Noun>Cache`, `<Noun>Publisher` interface | `OrderRepository` |
| Driven port package | Concern name under `internal/core/` — `repository/`, `bus/`, `mail/` | `repository` |
| Adapter (single role) | `<Technology><Noun>Repository`, `<Technology><Noun>Handler` | `PostgresOrderRepository` |
| Adapter file (dual-role) | `<role>.go` — `consumer.go`, `producer.go` inside a technology package | `kafka/consumer.go`, `kafka/producer.go` |
| DTO | `<Noun>Request`, `<Noun>Response` | `CreateOrderRequest` |
| Domain entity | Capitalized noun, no suffix | `Order`, `Customer` |
| Domain error | `Err<Noun>` sentinel or typed error | `ErrOrderNotFound` |

---

## File Skeletons

### `internal/core/domain/order.go`
```go
package domain

import "time"

type Order struct {
    ID         string
    CustomerID string
    Items      []OrderItem
    Status     OrderStatus
    CreatedAt  time.Time
}

type OrderStatus string

const (
    OrderStatusPending   OrderStatus = "pending"
    OrderStatusConfirmed OrderStatus = "confirmed"
)

// Domain method — business rule lives here, not in use case
func (o *Order) Confirm() error {
    if o.Status != OrderStatusPending {
        return ErrOrderAlreadyConfirmed
    }
    o.Status = OrderStatusConfirmed
    return nil
}
```

### `internal/core/domain/error.go`
```go
package domain

import "errors"

var (
    ErrOrderNotFound       = errors.New("order not found")
    ErrOrderAlreadyConfirmed = errors.New("order already confirmed")
)
```

### `internal/core/repository/order.go`
```go
package repository

import (
    "context"
    "<module>/internal/core/domain"
)

// OrderRepository is a driven port — it defines what infrastructure the app requires.
type OrderRepository interface {
    Save(ctx context.Context, order *domain.Order) error
    FindByID(ctx context.Context, id string) (*domain.Order, error)
}
```

### `internal/core/bus/order.go`
```go
package bus

import (
    "context"

    "<module>/internal/core/domain"
)

// OrderEventPublisher is a driven port — the app uses it to emit domain events.
// In a real project you'd define a dedicated event type in domain/ or here.
// For this skeleton the event payload is the entity itself.
type OrderEventPublisher interface {
    Publish(ctx context.Context, event domain.Order) error
}
```

### `internal/core/mail/sender.go`
```go
package mail

import "context"

// EmailSender is a driven port — the app uses it to send transactional emails.
type EmailSender interface {
    Send(ctx context.Context, to, subject, body string) error
}
```

### `internal/core/usecase/create_order.go`
```go
package usecase

import (
    "context"
    "fmt"

    "<module>/internal/core/domain"
    "<module>/internal/core/repository"
)

// CreateOrderUseCase is a driving port — it defines what the application exposes.
type CreateOrderUseCase interface {
    Execute(ctx context.Context, params CreateOrderParams) (*domain.Order, error)
}

// CreateOrderParams is a plain DTO — no framework types.
type CreateOrderParams struct {
    CustomerID string
    Items      []OrderItemParams
}

type OrderItemParams struct {
    ProductID string
    Quantity  int
}

// Ensure interface is implemented at compile time.
var _ CreateOrderUseCase = (*createOrderUseCase)(nil)

type createOrderUseCase struct {
    orderRepo repository.OrderRepository
}

// NewCreateOrderUseCase constructs the use case with its required driven ports.
func NewCreateOrderUseCase(repo repository.OrderRepository) CreateOrderUseCase {
    return &createOrderUseCase{orderRepo: repo}
}

func (uc *createOrderUseCase) Execute(ctx context.Context, params CreateOrderParams) (*domain.Order, error) {
    order := &domain.Order{
        ID:         newID(), // use a pkg/ helper, not an adapter
        CustomerID: params.CustomerID,
        Status:     domain.OrderStatusPending,
    }

    if err := uc.orderRepo.Save(ctx, order); err != nil {
        return nil, fmt.Errorf("create order: %w", err)
    }

    return order, nil
}
```

### `internal/adapter/http/handler/order_handler.go`
```go
package handler

import (
    "encoding/json"
    "net/http"

    "<module>/internal/adapter/http/dto"
    "<module>/internal/core/usecase"
)

type OrderHandler struct {
    createOrder usecase.CreateOrderUseCase  // depends on the port interface, not the concrete struct
}

func NewOrderHandler(createOrder usecase.CreateOrderUseCase) *OrderHandler {
    return &OrderHandler{createOrder: createOrder}
}

func (h *OrderHandler) CreateOrder(w http.ResponseWriter, r *http.Request) {
    var req dto.CreateOrderRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "bad request", http.StatusBadRequest)
        return
    }

    order, err := h.createOrder.Execute(r.Context(), req.ToParams())
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(dto.OrderFromDomain(order))
}
```

### `internal/adapter/postgres/order_repository.go`
```go
package postgres

import (
    "context"
    "database/sql"

    "<module>/internal/core/domain"
    "<module>/internal/core/repository"
)

// Ensure interface is satisfied at compile time.
var _ repository.OrderRepository = (*OrderRepository)(nil)

type OrderRepository struct {
    db *sql.DB
}

func NewOrderRepository(db *sql.DB) *OrderRepository {
    return &OrderRepository{db: db}
}

func (r *OrderRepository) Save(ctx context.Context, order *domain.Order) error {
    _, err := r.db.ExecContext(ctx,
        `INSERT INTO orders (id, customer_id, status) VALUES ($1, $2, $3)`,
        order.ID, order.CustomerID, string(order.Status),
    )
    return err
}

func (r *OrderRepository) FindByID(ctx context.Context, id string) (*domain.Order, error) {
    row := r.db.QueryRowContext(ctx,
        `SELECT id, customer_id, status FROM orders WHERE id = $1`, id)

    var o domain.Order
    if err := row.Scan(&o.ID, &o.CustomerID, &o.Status); err != nil {
        if err == sql.ErrNoRows {
            return nil, domain.ErrOrderNotFound
        }
        return nil, err
    }
    return &o, nil
}
```

### `internal/adapter/kafka/consumer.go`
```go
package kafka

import (
    "context"
    "encoding/json"

    "<module>/internal/core/usecase"
)

// Consumer handles incoming Kafka messages (driving adapter — calls into the app).
type Consumer struct {
    createOrder usecase.CreateOrderUseCase
}

func NewConsumer(createOrder usecase.CreateOrderUseCase) *Consumer {
    return &Consumer{createOrder: createOrder}
}

func (c *Consumer) HandleMessage(ctx context.Context, msg []byte) error {
    var params usecase.CreateOrderParams
    if err := json.Unmarshal(msg, &params); err != nil {
        return err
    }
    _, err := c.createOrder.Execute(ctx, params)
    return err
}
```

### `internal/adapter/kafka/producer.go`
```go
package kafka

import (
    "context"
    "encoding/json"

    "<module>/internal/core/bus"
    "<module>/internal/core/domain"
)

// Producer publishes domain events to Kafka (driven adapter — implements bus port).
type Producer struct {
    // kafka writer client
}

func NewProducer() *Producer {
    return &Producer{}
}

var _ bus.OrderEventPublisher = (*Producer)(nil)

func (p *Producer) Publish(ctx context.Context, event domain.OrderEvent) error {
    data, _ := json.Marshal(event)
    // publish to Kafka topic
    return nil
}
```

### `cmd/<app>/main.go`
```go
package main

import (
    "database/sql"
    "log"
    "net/http"

    _ "github.com/lib/pq"

    httpserver "<module>/internal/adapter/http"
    "<module>/internal/adapter/kafka"
    "<module>/internal/adapter/postgres"
    "<module>/internal/config"
    "<module>/internal/core/usecase"
)

func main() {
    cfg := config.Load()

    db, err := sql.Open("postgres", cfg.DatabaseURL)
    if err != nil {
        log.Fatal(err)
    }

    // Wire driven adapters
    orderRepo := postgres.NewOrderRepository(db)

    // Wire use cases (core) — inject driven ports
    createOrder := usecase.NewCreateOrderUseCase(orderRepo)

    // Wire driving adapters — inject use case interfaces
    kafkaCons := kafka.NewConsumer(createOrder)
    srv       := httpserver.NewServer(cfg, createOrder)

    log.Fatal(http.ListenAndServe(cfg.Addr, srv))
}
```
