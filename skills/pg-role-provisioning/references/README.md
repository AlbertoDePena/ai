# PostgreSQL provisioning scripts

A small toolkit for standing up application databases and logins on a
PostgreSQL cluster, using a four-role permission model built entirely on
a **namespace you choose** — every role name and the application schema
name derive from it. There's no built-in or default namespace; you pass
one every time with `-n` (and it's a required `role_prefix` variable for
the SQL files).
Everything runs under a **master (admin) account** and is safe to re-run.

## Contents

| Script | Kind | What it does |
| --- | --- | --- |
| [`create-application-databases.sh`](#create-application-databasessh) | bash + psql | Creates an application database **and** its DBOS system database, then applies the roles/grants to each. |
| [`setup-database-roles.pgsql.sql`](#setup-database-rolespgsqlsql) | SQL | The role + grant logic for a **single** database. Applied by the script above; can also be run on its own. |
| [`create-login.sh`](#create-loginsh) | bash + psql | Creates or updates **one** login role and attaches it to exactly one permission role. |
| [`create-login.pgsql.sql`](#create-loginpgsqlsql) | SQL | The create-or-update-and-attach logic for a single login. Driven by the script above. |
| [`migrate-dbos-system.sh`](#migrate-dbos-systemsh) | bash + dbos CLI | Runs `dbos migrate` to create the DBOS system tables in an app's `<app>_dbos_system` database and grants a permission role access to them. |

The three `.sh` files are the entry points you run. The two `.pgsql.sql`
files hold the SQL that the first two execute and are read from the same
directory; `migrate-dbos-system.sh` instead drives the DBOS Go CLI.

---

## The role model

Four **cluster-wide, `NOLOGIN` permission roles** carry all privileges.
Individual **login roles** are granted membership in exactly one of them;
logins never receive privileges directly.

All four role names, and (by default) the application schema they're
granted on, are derived from a single **namespace** you choose — there
is no default namespace, you must pass one (`-n`) every time. For a
namespace of, say, `acme`:

| Role (namespace = `acme`) | Access | Intended for |
| --- | --- | --- |
| `acme_application` | read/write (DML) | application service accounts |
| `acme_application_readonly` | read-only | application service accounts |
| `acme_developer` | read/write (DML) | people |
| `acme_developer_readonly` | read-only | people |

Pick any other namespace (e.g. `contoso`) and you get
`contoso_application`, `contoso_application_readonly`, `contoso_developer`,
`contoso_developer_readonly` instead — same model, different root name.
**Use the same namespace consistently across all three scripts for a
given cluster/project**; it isn't stored anywhere in the database itself,
so nothing will complain if you mix namespaces, but logins created under
one namespace won't be valid `access_role` values for another.

Key properties of the model:

- **Application objects live in a dedicated schema** (default: the
  same name as `<namespace>` itself — configurable independently with
  `-s`/`schema_name` if you want the schema named differently from the
  role prefix). `public` is locked down
  completely and the permission roles are granted on that schema instead.
  The database's `search_path` is set to `<schema>, public`, so sessions
  operate in the context of that schema by default.
- **No `CREATE` on the application schema.** None of the four roles can
  create tables, views, functions, or schemas. DDL is done through the
  master account; the roles only get DML / `USAGE` / `EXECUTE`.
- **`public` and `PUBLIC` are locked down.** Postgres' implicit `PUBLIC`
  grants (`CONNECT` on the db, `USAGE`/`CREATE` on `public`) are revoked,
  and no permission role is granted on `public`, so access must come
  through membership in one of the four roles on the application schema.
- **Default privileges** are set so the roles automatically get the
  right access on **future** objects created in the application schema.
- The permission roles are cluster-wide; their **grants are per-database**.
  Creating a new database re-runs the grants for that database.

Login-role membership is kept **exclusive**: attaching a login to one
role first revokes it from the other three.

---

## Prerequisites

- A `psql` client on your PATH (PostgreSQL 13+; the scripts use
  `DROP DATABASE ... WITH (FORCE)` semantics and `\gexec`).
  - On macOS via Homebrew: `brew install libpq`, then add its keg-only
    bin to your PATH:
    ```bash
    export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
    ```
- A master/admin account that can `CREATE DATABASE` and `CREATE ROLE`.

---

## Connection string & passwords

Both `.sh` scripts take the master connection with **`-c <conninfo>`** —
a full libpq **URI** or **keyword** string, **without the password**:

```
postgresql://admin@localhost:5432/postgres
"host=localhost port=5432 user=admin dbname=postgres"
```

The database named in the connection string is just a **maintenance db**
the master account can reach (e.g. `postgres`) — the scripts switch to
the target databases themselves.

Passwords are **prompted for (hidden)** by default so they never land in
`argv` or shell history:

- **Master password** — prompted, unless `PGPASSWORD` is set in the
  environment (unattended runs) or `~/.pgpass` covers it. Leaving the
  prompt blank defers to `~/.pgpass`, a password embedded in `-c`, or
  psql's own prompt.
- **New login's password** (`create-login.sh` only) — prompted, unless
  `LOGIN_PASSWORD` is set in the environment.

> Keep the password **out** of the `-c` string. If you must embed it in a
> URI, percent-encode special characters (e.g. `@` → `%40`). Note that
> inline env assignments (`PGPASSWORD=… ./script.sh`) can still be
> captured by interactive shell history — prefer the prompt or `~/.pgpass`.

---

## `create-application-databases.sh`

Creates two databases for an application and applies the role model to
each:

- `<app>` — the application database
- `<app>_dbos_system` — its DBOS system database (DBOS' default
  `<app_db_name>_dbos_system` convention)

It connects once to the maintenance db in the connection string, creates
the databases (idempotently — skipped if they already exist), then uses
`\c` to hop into each new database (reusing the same credentials) and
applies `setup-database-roles.pgsql.sql`, passing along the chosen
namespace and schema name as psql variables.

**Usage**

```
./create-application-databases.sh -c <conninfo> -a <app_name> \
    -n <namespace> [-s <schema>]
```

| Option | Required | Description |
| --- | --- | --- |
| `-c <conninfo>` | yes | Master connection string (password-less). |
| `-a <app_name>` | yes | Application db name. Must match `^[A-Za-z_][A-Za-z0-9_]*$`. The DBOS system db name is derived as `<app_name>_dbos_system`. |
| `-n <namespace>` | yes | Root namespace for the four permission roles. Must match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `-s <schema>` | no | Application schema name. Default: same as `<namespace>`. Must match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `-h` | | Show help. |

**Example**

```bash
./create-application-databases.sh \
  -c 'postgresql://admin@localhost:5432/postgres' \
  -a orders_api -n acme
# prompts for the master password, then creates:
#   orders_api  and  orders_api_dbos_system
# with permission roles acme_application, acme_application_readonly,
# acme_developer, acme_developer_readonly granted on schema "acme"
```

Re-running is a safe no-op: existing databases are left in place and the
grants are simply re-applied. Re-running with a **different** `-n`/`-s`
adds a second, independent namespace/schema alongside any existing one
rather than replacing it — it doesn't remove roles or schemas from a
prior run.

---

## `setup-database-roles.pgsql.sql`

The role + grant logic for **one** database, scoped to whatever database
`psql` is connected to (`current_database()`). It:

1. Creates the four permission roles (`<namespace>_application`, etc.)
   if they don't already exist (no-op if another database already
   created them). **Always applied.**
2. Locks down `public`: revokes the implicit `PUBLIC` grants on the
   database and `public`, and strips any permission-role grants a
   previous version of this script may have placed on `public`.
   **Always applied.**
3. Grants each role `CONNECT` on this database. **Always applied** —
   this is what lets the roles reach the database at all now that
   `PUBLIC`'s implicit `CONNECT` was revoked in step 2.
4. **Only when `create_app_schema` is true (the default):** creates the
   application schema (`schema_name`), sets the database's
   `search_path` to `<schema_name>, public`, and grants each role the
   appropriate schema privileges plus default privileges for future
   objects.

It does **not** create any logins, and it leaves the `dbos` schema
(managed by `migrate-dbos-system.sh`) untouched.

Takes two required psql variables, `role_prefix` and `schema_name`, and
one optional variable, `create_app_schema` (`true`/`false`, default
`true` if omitted). `create-application-databases.sh` supplies all of
these — `role_prefix` and `schema_name` via `-v` (the same `schema_name`
value for both the app and system databases), and `create_app_schema`
via `\set` per database (`true` for the app db, `false` for the DBOS
system db, since DBOS keeps its tables in its own `dbos` schema and
never touches the application schema — see "Why still run
`setup-database-roles.pgsql.sql` on the system db?" below).

**Run it directly** (e.g. to re-apply grants to an existing database):

```bash
# Full treatment: roles + public lockdown + CONNECT + app schema/grants
psql -v ON_ERROR_STOP=1 \
  'postgresql://admin@localhost:5432/orders_api' \
  -v role_prefix=acme \
  -v schema_name=acme \
  -f setup-database-roles.pgsql.sql

# Lockdown + CONNECT only, no application schema (e.g. a DBOS system db)
psql -v ON_ERROR_STOP=1 \
  'postgresql://admin@localhost:5432/orders_api_dbos_system' \
  -v role_prefix=acme \
  -v schema_name=acme \
  -v create_app_schema=false \
  -f setup-database-roles.pgsql.sql
```

---

## `create-login.sh`

Creates (or updates) **one** login role and attaches it to a single
permission role. If the login already exists, its **password is
updated** rather than left unchanged.

Login roles and role membership are cluster-wide, so this can connect to
any database the master account can reach — the per-database `CONNECT`
and schema grants already live on the permission roles.

**Usage**

```
./create-login.sh -c <conninfo> -u <login_name> -r <access_role> \
    -n <namespace>
```

| Option | Required | Description |
| --- | --- | --- |
| `-c <conninfo>` | yes | Master connection string (password-less). |
| `-u <login_name>` | yes | Login role to create/update. Must match `^[A-Za-z_][A-Za-z0-9_]*$` and must not be one of the four permission role names. |
| `-r <access_role>` | yes | One of `<namespace>_application`, `<namespace>_application_readonly`, `<namespace>_developer`, `<namespace>_developer_readonly`. |
| `-n <namespace>` | yes | Root namespace the roles were created under. Must match the namespace passed to `create-application-databases.sh`. |
| `-h` | | Show help. |

**Example**

```bash
./create-login.sh \
  -c 'postgresql://admin@localhost:5432/postgres' \
  -u acme_app_orders -r acme_application -n acme
# prompts for the master password, then for the new login's password,
# then creates/updates acme_app_orders as a member of acme_application
```

Behaviour worth knowing:

- **Password rotation** — re-run with a different `LOGIN_PASSWORD` (or a
  different value at the prompt) to change an existing login's password.
- **Tier change** — re-run with a different `-r` to move a login between
  tiers; membership stays exclusive (the other three roles are revoked).
- The `WARNING: role "…" has not been granted membership in role "…"`
  lines during a run are the harmless no-op revokes (Postgres 16+ phrases
  them as warnings). Safe to ignore.
- If `-n` doesn't match a namespace that actually has roles created
  under it (via `create-application-databases.sh`), `-r` will fail
  validation (role name looks right, but `GRANT` will error because the
  role doesn't exist).

---

## `create-login.pgsql.sql`

The SQL behind `create-login.sh`. It reads four psql variables —
`role_prefix`, `login_name`, `login_password`, `access_role` — creates or
updates the login, keeps its membership exclusive to `access_role`
(validated against the four roles built from `role_prefix`), and prints
a confirmation row. You normally invoke it through `create-login.sh`,
but it can be run directly:

```bash
psql -v ON_ERROR_STOP=1 \
  'postgresql://admin@localhost:5432/postgres' \
  -v role_prefix=acme \
  -v login_name=acme_app_orders \
  -v login_password='S3cret!' \
  -v access_role=acme_application \
  -f create-login.pgsql.sql
```

(Passing the password via `-v` puts it in `argv`; prefer `create-login.sh`,
which routes it through a prompt / env var instead.)

---

## `migrate-dbos-system.sh`

Runs the DBOS system-table migration against an application's
`<app>_dbos_system` database using the **DBOS Go CLI**
(`github.com/dbos-inc/dbos-transact-golang/cmd/dbos`).

`dbos migrate` creates the DBOS system tables (in the `dbos` schema by
default: `workflow_status`, `operation_outputs`, `queues`,
`notifications`, etc.). Its `--app-role` flag grants the role your DBOS
application runs as — one of the four permission roles for your
namespace — `USAGE` on the `dbos` schema and full DML on those tables,
so the DBOS schema plugs into the same role model as everything else.
Run it under the **master** account.

**Usage**

```
./migrate-dbos-system.sh -c <conninfo> -n <namespace> \
    [-r <app_role>] [-s <schema>] [-i]
```

| Option | Required | Description |
| --- | --- | --- |
| `-c <conninfo>` | yes | Password-less `postgres://` / `postgresql://` **URI** for the DBOS system db (its user and database), e.g. `postgresql://admin@localhost:5432/orders_api_dbos_system`. |
| `-n <namespace>` | yes | Root namespace the permission roles were created under. Used to validate `-r` and to build its default. |
| `-r <app_role>` | no | Permission role your app runs as; granted access to the system tables. Default `<namespace>_application`. |
| `-s <schema>` | no | DBOS schema name. Default is the CLI's own default, `dbos`. |
| `-i` | no | Install the `dbos` CLI via `go install` if it isn't on PATH. |
| `-h` | | Show help. |

Unlike the other scripts, `-c` must be a **URI** (not a keyword string):
the script injects the prompted password into the URI and passes the
result to the CLI via the `DBOS_SYSTEM_DATABASE_URL` environment
variable, keeping it out of `argv`.

**Prerequisites**

- The `<app>_dbos_system` database already exists (created by
  `create-application-databases.sh -a <app>`).
- Go 1.23+ and the `dbos` CLI on PATH — install with:
  ```bash
  go install github.com/dbos-inc/dbos-transact-golang/cmd/dbos@latest
  ```
  and put `$(go env GOPATH)/bin` on your PATH, or pass `-i` to let the
  script install it.

**Example**

```bash
./migrate-dbos-system.sh \
  -c 'postgresql://admin@localhost:5432/orders_api_dbos_system' \
  -r acme_application -n acme
# prompts for the master password, creates the DBOS system tables,
# and grants acme_application access to them
```

Re-running is idempotent — the CLI reports
`DBOS migrations completed successfully` and leaves existing tables in
place.

### Why still run `setup-database-roles.pgsql.sql` on the system db?

DBOS keeps all its tables in the **`dbos`** schema, never `public` or
your application schema, and `dbos migrate --app-role` grants your role
everything it needs there. So the application-schema **table/sequence
grants** from `setup-database-roles.pgsql.sql` would be entirely unused
in the system database.

`dbos migrate` does **not**, however, lock down `PUBLIC` or grant the app
role an explicit database `CONNECT` — after a bare migrate the role can
only connect because Postgres' default `PUBLIC` `CONNECT` is still open,
which means *any* role could connect and use the system db's `public`
schema. `setup-database-roles.pgsql.sql` is what closes that: it revokes
the default `PUBLIC` grants, locks down `public`, and gives the app role
an explicit `CONNECT`.

So `create-application-databases.sh` still runs
`setup-database-roles.pgsql.sql` against the system db — but with
`create_app_schema=false`, so it only does the **`public`/`PUBLIC`
lockdown + explicit `CONNECT`** part; it skips creating an application
schema there, since nothing would ever use it. `dbos migrate` then
layers the `dbos`-schema grants on top, leaving the `dbos` schema itself
intact.

---

## Typical workflow

```bash
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"   # macOS/Homebrew psql
CONN='postgresql://admin@localhost:5432/postgres'
NS='acme'   # pick your namespace once, reuse it everywhere below

# 1. Provision the application + DBOS system databases
./create-application-databases.sh -c "$CONN" -a orders_api -n "$NS"

# 2. Migrate the DBOS system database (creates the dbos schema/tables)
./migrate-dbos-system.sh \
  -c 'postgresql://admin@localhost:5432/orders_api_dbos_system' \
  -r "${NS}_application" -n "$NS" -i

# 3. Attach a read/write service account for the app
./create-login.sh -c "$CONN" -u "${NS}_app_orders" -r "${NS}_application" -n "$NS"

# 4. Attach a read-only login for a developer
./create-login.sh -c "$CONN" -u "${NS}_jdoe" -r "${NS}_developer_readonly" -n "$NS"
```

Because the DBOS system database also uses the namespace's permission
roles, grant the application's DBOS login the `<namespace>_application`
role (read/write) — DBOS needs write access to its system database. The
same login created in step 3 therefore works for both `orders_api` and
`orders_api_dbos_system`.

---

## Notes & conventions

- **Idempotent.** All five scripts are safe to re-run; role creation is
  guarded, every `GRANT`/`REVOKE` is a no-op when already in effect, and
  `dbos migrate` skips tables that already exist.
- **DDL stays with the master account.** The permission roles cannot
  create objects; create tables as the admin in the application schema
  (the default `search_path` resolves there), and the default privileges
  hand the right access to the roles automatically.
- **Identifier safety.** Database names, login names, namespaces, and
  schema names are all validated against `^[A-Za-z_][A-Za-z0-9_]*$`
  before being used in SQL.
- **One namespace per project/cluster, by convention.** Nothing in
  Postgres enforces this — you *can* run the toolkit multiple times with
  different `-n` values against the same cluster to get separate,
  independent sets of permission roles/schemas (e.g. for multi-tenant
  setups) — but keep track of which namespace goes with which app, since
  `create-login.sh` / `migrate-dbos-system.sh` only validate that
  `-r`/`-n` are shaped like a valid role name, not that the role was
  actually created.
- **Dropping a database in use** requires terminating open sessions;
  on Postgres 13+ use `DROP DATABASE <name> WITH (FORCE)`.
