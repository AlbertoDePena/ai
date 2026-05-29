---
name: go-hexagonal
description: >
  Enforces the hexagonal architecture (ports and adapters) pattern in Go applications.
  Use this skill whenever the user is: creating a new Go project, reviewing Go code for
  architecture violations, writing Go interfaces or adapters, reorganizing an existing Go
  codebase, asking about Go project structure, or mentioning ports, adapters, domain logic,
  use cases, or application layers in a Go context. Even if they don't say "hexagonal" —
  trigger whenever Go + architecture/structure + any of: services, repositories, handlers,
  interfaces, adapters, usecases, domain, infra, or clean architecture.
---

# Go Hexagonal Architecture Skill

## Overview

This skill enforces a **strict** hexagonal (ports & adapters) layout for Go applications.
The core rule: **domain logic never depends on infrastructure**. Dependencies always point inward.

Read `references/structure.md` for the canonical folder layout and file naming rules.
Read `references/patterns.md` for port/adapter code patterns, anti-patterns, and refactoring recipes.

---

## Workflow by Task

### 1. Scaffold a New Project

1. Read `references/structure.md` — use the canonical layout verbatim.
2. Ask for the domain name(s) (e.g. `order`, `user`, `payment`) if not provided.
3. Generate all directories and skeleton files in one pass.
4. Produce a `README.md` explaining the layers and where new code goes.

### 2. Review Existing Code

1. Ask the user to share their folder tree (or read uploaded files).
2. Check against the rules in `references/structure.md` — list every violation.
3. For each violation, state: what's wrong, which rule it breaks, and how to fix it.
4. Output a prioritized fix list (breaking violations first, style second).

### 3. Write Ports and Adapters

1. Read `references/patterns.md` — follow the naming and interface conventions exactly.
2. Driving ports (use case interfaces) go in `internal/core/usecase/` alongside their implementation. Driven ports (repositories, publishers, etc.) go in dedicated packages under `internal/core/` — always interfaces, never structs.
3. Adapters go in `internal/adapter/` — one package per technology (e.g. `http/`, `postgres/`, `kafka/`). A single package can hold both driving and driven roles (e.g. `kafka/consumer.go` + `kafka/producer.go`).
4. Use cases in `internal/core/usecase/` depend only on driven port interfaces and domain — never on adapters.

### 4. Reorganize an Existing Project

1. Read `references/structure.md` and `references/patterns.md`.
2. Map every existing file to its target location in the canonical layout.
3. Present a **migration plan** as a table: `current path → target path → reason`.
4. Warn about circular imports that will arise and how to break them.
5. Generate the refactored files in the correct locations; do not leave the old layout in place.

---

## Hard Rules (never violate)

| Rule | Detail |
|------|--------|
| **No infra imports in core** | `internal/core/` must not import `internal/adapter/`, `database/sql`, HTTP libs, ORMs, etc. |
| **Driving ports live in `usecase/`** | Use case interfaces are defined alongside their implementation in `internal/core/usecase/`. |
| **Driven ports are pure interfaces** | Driven port packages (`repository/`, `bus/`, `mail/`) under `core/` contain only interfaces — no structs, no implementations. |
| **Adapters own their types** | Adapters translate between external types and domain types — never expose external types to core. |
| **One adapter per technology** | HTTP, gRPC, Postgres, Kafka — each technology gets its own package under `internal/adapter/`. A single package can contain both driving and driven files (e.g. `kafka/consumer.go` + `kafka/producer.go`). |
| **`main.go` is the only wiring point** | Dependency injection happens in `cmd/<app>/main.go` only. |
| **No `init()` side effects in core** | `init()` is only acceptable in `cmd/` or adapter packages. |

---

## Quick Reference: Layer → Directory

| Layer | Directory | Allowed dependencies |
|-------|-----------|----------------------|
| Domain entities & value objects | `internal/core/domain/` | None (pure Go) |
| Use cases + driving ports | `internal/core/usecase/` | `domain/`, driven port packages |
| Driven port interfaces | `internal/core/{repository,bus,mail,...}/` | `domain/` only |
| Adapters | `internal/adapter/{http,postgres,kafka,...}/` | `core/usecase/` (driving role), driven port packages (driven role), `core/domain/` |
| Wiring / entrypoint | `cmd/<app>/` | Everything |
| Shared config & infra helpers | `internal/config/`, `pkg/` | No `core/` imports |
