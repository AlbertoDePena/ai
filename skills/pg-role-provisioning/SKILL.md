---
name: pg-role-provisioning
description: Provision PostgreSQL application databases (app + DBOS system + an unlogged key/value cache db), a four-tier permission-role model (read/write and read-only roles for both applications and developers), login roles, and DBOS system-database migrations — all built on a namespace the caller supplies (no hard-coded role prefix or schema name). Use this skill whenever the user wants to set up new application/DBOS/cache databases, create or rotate PostgreSQL login roles tied to a permission-role model, cache key/value data in PostgreSQL instead of Redis, or wants a role-prefix/schema naming convention parameterized around their own namespace (e.g. "acme", "orders", their company name). Trigger on requests like "set up a new database for my app with roles", "create a postgres login for this service", "migrate the DBOS system database", "add a Postgres-backed cache to my service", or "give me a role-based Postgres provisioning setup with my own namespace".
---

# PostgreSQL role-based provisioning

This skill bundles a small toolkit of three shell scripts + two SQL
files that provision PostgreSQL databases under a **four-role
permission model**: `<namespace>_application`,
`<namespace>_application_readonly`, `<namespace>_developer`,
`<namespace>_developer_readonly`, all granted on a dedicated application
schema (default: same name as `<namespace>`) instead of `public`.

Each application gets **three databases** — `<app>`, `<app>_cache`
and `<app>_dbos` — all sharing the same namespace roles and schema
name. The cache database holds an `UNLOGGED`
`cache(key, value, expires_at)` table and runs with
`synchronous_commit = off`; it is a separate database because that
setting is per-database and must not apply to `<app>`.

`<app>_dbos` is deliberately **shorter** than the name DBOS derives from
the application database on its own, so an application must be pointed
at it explicitly — `DBOS_SYSTEM_DATABASE_URL`, or the equivalent field
in its DBOS config. Mention this when scaffolding a DBOS app against
these databases; leaving it to the default lands the app on a database
that was never provisioned. Nothing in the toolkit derives the name:
`migrate-dbos-system.sh` and `dbosctl sysdb migrate` both take the
system database URL as an argument.

The namespace is a **required parameter** everywhere — pass
`-n <namespace>` (and optionally `-s <schema>` if the schema should be
named differently from the role prefix) every time you run one of these
scripts. There is no default namespace and no default schema-naming
suffix; the caller always supplies the namespace they want. Full
behavioral details, the role model rationale, and all script options
are in `references/README.md` — **read it before making non-trivial
changes** or explaining the model to the user in depth; this file only
covers the mechanics of using the bundled scripts.

## When to use this

- Standing up a new application's databases + roles/logins from scratch.
- Adding a PostgreSQL-backed key/value cache instead of running Redis.
- Adding a login (service account or developer) to an existing setup.
- Running the DBOS system-table migration for a DBOS-backed app.
- Any project that wants this role-based permission model under its own
  namespace — just pass `-n <their namespace>` (and optionally `-s`),
  no script editing needed.

## Files

```
scripts/
  create-application-databases.sh   # create <app> + <app>_cache + <app>_dbos dbs, apply roles to all
  setup-database-roles.pgsql.sql    # role/grant logic for ONE database (invoked by the script above)
  create-login.sh                   # create/update one login, attach to one permission role
  create-login.pgsql.sql            # SQL behind create-login.sh
  migrate-dbos-system.sh            # run `dbosctl sysdb migrate`, grant the app role access to DBOS tables
references/
  README.md                         # full documentation: role model, all options, workflow, gotchas
  cache.md                          # the <app>_cache database: table, query patterns, trade-offs
```

Copy the whole `scripts/` directory into the user's project (all five
files must stay together — the `.sh` files locate their `.pgsql.sql`
siblings via `$SCRIPT_DIR`) and `chmod +x` the three `.sh` files.

## Core workflow

Ask the user (or infer from context) which namespace they want — there's
no default, so `-n` is required on every invocation. Pick one namespace
per project and reuse it consistently across all three scripts; it
isn't stored in the database, so nothing enforces consistency
automatically:

```bash
CONN='postgresql://admin@localhost:5432/postgres'   # master conninfo, no password
NS='acme'   # the user's chosen namespace — required, no default

# 1. Create the app db + cache db + DBOS system db, apply the role model
#    to all three (add -k to skip the cache db)
./create-application-databases.sh -c "$CONN" -a orders_api -n "$NS"

# 2. Migrate the DBOS system database
./migrate-dbos-system.sh \
  -c 'postgresql://admin@localhost:5432/orders_api_dbos' \
  -r "${NS}_application" -n "$NS" -i

# 3. Attach a read/write service-account login for the app
./create-login.sh -c "$CONN" -u "${NS}_app_orders" -r "${NS}_application" -n "$NS"

# 4. Attach a read-only login for a developer
./create-login.sh -c "$CONN" -u "${NS}_jdoe" -r "${NS}_developer_readonly" -n "$NS"
```

One login covers all three databases — they share the namespace's
roles — but each is a separate connection, so the app needs a second
pool pointed at `<app>_cache`. Nothing is transactional across them.

Passwords are always prompted (hidden) unless `PGPASSWORD` /
`LOGIN_PASSWORD` are set in the environment — never pass them on the
command line or hard-code them into a wrapper script.

Every identifier (`-a`, `-n`, `-s`, `-u`, database/schema names) is
validated against `^[A-Za-z_][A-Za-z0-9_]*$` before it's interpolated
into SQL — if the user wants a namespace or app name outside that
pattern, tell them to pick a valid identifier instead of relaxing the
check.

## Namespace and schema naming

- `-n <namespace>` is **required** in every script — there's no
  built-in default. Always ask the user for (or otherwise determine)
  the namespace they want before running any of these scripts.
- `-s <schema>` (in `create-application-databases.sh` and
  `setup-database-roles.pgsql.sql` directly) defaults to the same name
  as `-n <namespace>` if omitted — e.g. namespace `acme` gets schema
  `acme`. There is no suffix or other transformation applied by
  default. Pass `-s` explicitly only if the user wants the schema named
  differently from the role prefix.
- `create-login.sh` and `migrate-dbos-system.sh` don't take a `-s`
  flag — they only need the namespace to validate/build role names, not
  the schema name.

## If the user wants to rename the namespace on an *existing* database

Changing `-n` only affects roles created by future runs — it does not
rename or migrate roles/grants already created under the old namespace.
To move an existing database from one namespace to another:

1. Run `setup-database-roles.pgsql.sql` (or
   `create-application-databases.sh`, which is idempotent) with the
   **new** namespace against the existing database — this creates the
   new roles/schema and grants them, leaving the old ones in place.
2. Re-run `create-login.sh` with the new namespace for each login that
   needs to move to a new-namespace role — this grants the new role and
   revokes the old namespace's role from that login (membership is kept
   exclusive within a namespace's four roles, but a login could still
   hold roles from two different namespaces if you're mid-migration).
3. Once nothing depends on the old namespace's roles anymore, drop them
   manually (`DROP ROLE <old>_application ...`) and optionally drop the
   old schema — the scripts never do this automatically since dropping
   a schema in use, or a role still owning objects, needs a deliberate,
   reviewed decision, not an idempotent script.

This isn't automated in the toolkit; walk the user through it explicitly
rather than assuming a single script run handles a rename.

## The app schema is skipped on the DBOS system db

`setup-database-roles.pgsql.sql` takes an optional `create_app_schema`
psql variable (`true`/`false`, default `true`). `create-application-databases.sh`
sets it to `true` for the app db and `false` for the `<app>_dbos`
db, via `\set create_app_schema ...` before each `\i` call — the same
`schema_name` value is passed once, up front, for both databases; the
flag just controls whether that run actually creates the schema.

When `false`, role creation and the `public`/`PUBLIC` lockdown still
happen (that's the actual reason to run this script against the DBOS
system db at all — `dbosctl sysdb migrate` never does that hardening);
the application-schema creation and its schema-level grants are skipped.
This avoids leaving a pointless, empty app schema sitting in the DBOS
system database, since DBOS puts its real tables in its own `dbos`
schema instead.

The flag also decides **which roles get `CONNECT`**:

- `true` (app db) — all four tiers.
- `false` (DBOS system db) — only `<namespace>_application`, and the
  other three are explicitly *revoked* so re-running tightens a system
  db provisioned by an earlier version. `dbosctl sysdb migrate
  --app-role` grants the `dbos` schema to exactly one role, so `CONNECT`
  for the other three only bought a session in which every query failed.

Two related traps when working on the DBOS system db:

- `--app-role` must be the **application** role. `dbosctl` emits
  `GRANT ALL PRIVILEGES` (verify with `--print-user-role`); it has no
  read-only mode, so pointing it at a `_readonly` tier silently makes
  that tier read/write.
- `dbos.workflow_status` stores serialized workflow `inputs`, `output`
  and `request` plus the authenticated user and roles. Read access there
  exposes application payloads and caller identity, so widen it via a
  column-projecting **view**, never by granting `SELECT` on the table.

If asked to change this default, or to run the roles script standalone,
remember: omitting `-v create_app_schema=...` behaves as `true` (full
backward-compatible behavior).

## The cache database

`create-application-databases.sh` provisions `<app>_cache` alongside the
other two and applies `setup-database-roles.pgsql.sql` with
`create_app_schema=true` **and** `create_cache_table=true` — the only
database that gets the second flag. That adds, in the application
schema:

```sql
CREATE UNLOGGED TABLE cache (
    key        text        PRIMARY KEY,
    value      jsonb       NOT NULL,
    expires_at timestamptz NOT NULL
) WITH (fillfactor = 70, autovacuum_vacuum_scale_factor = 0.02,
        autovacuum_vacuum_cost_delay = 0);
CREATE INDEX cache_expires_at_idx ON cache (expires_at);
ALTER DATABASE <app>_cache SET synchronous_commit = off;
```

`-k` skips the whole database. `references/cache.md` has the table, the
set/get/sweep/flush queries, and the trade-offs — **read it before
advising anyone to rely on this cache**, and before changing the DDL.
The points most likely to come up:

- **Why its own database.** `UNLOGGED` is per-table but
  `synchronous_commit` is per-**database**; there is no table-level
  setting. A cache table in `<app>` would mean relaxing durability for
  every row in `<app>`. Don't "simplify" the cache back into the
  application database, and don't set `create_cache_table=true` against
  any database holding data you'd mind losing.
- **The two settings aren't redundant.** An unlogged table writes no WAL
  for its data, but a write transaction still assigns an XID and writes
  a commit record, which is fsynced unless `synchronous_commit` is off.
- **`UNLOGGED` means crash → empty.** PostgreSQL truncates the table
  during crash recovery (a clean restart keeps the rows) and its
  contents never reach a physical standby. Code must treat a miss on a
  just-written key as normal.
- **Reads must filter `expires_at > now()`.** The sweep is lazy, so
  expired rows stay readable until it runs. Dropping that predicate is
  a correctness bug, not a missed optimisation.
- **Every refresh is a non-HOT update.** `expires_at` is indexed and
  rewritten on each upsert, so a HOT update is impossible — hence the
  tightened autovacuum storage parameters. `cache.md` covers the
  index-free variant that trades sweep cost for HOT updates.
- **`CREATE TABLE IF NOT EXISTS` won't migrate an existing table.** If
  the cache DDL changes, an already-provisioned cache table is left
  exactly as it was. Drop it — the data is disposable — and re-run.

The table is created by the provisioning script rather than by
application migrations for the same reason everything else here is: none
of the four permission roles has `CREATE` on the schema. Grants come
from the normal role blocks (so all four tiers get their usual DML),
plus an explicit `TRUNCATE` on `cache` for the two read/write tiers,
since `TRUNCATE` isn't part of the DML the model otherwise hands out.

## Editing the SQL

If you need to change what the permission roles get access to (new
default privileges, a new role tier, etc.), edit
`scripts/setup-database-roles.pgsql.sql`. It reads `role_prefix` and
`schema_name` from a temp table populated from psql `-v` variables (psql
does **not** substitute `:'variables'` inside `$$ ... $$` dollar-quoted
blocks, which is why the temp-table indirection exists — don't
"simplify" it back to direct `:'role_prefix'` references inside a `DO $$`
block, it will silently fail to substitute). Every dynamic identifier
(role name, schema name) must go through `EXECUTE format('...', %I, ...)`
rather than being spliced into a plain SQL string.

One more trap in that file: the revoke that strips PUBLIC's implicit
`EXECUTE` on application-schema functions is deliberately **global**
(`ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, no
`IN SCHEMA`). The schema-scoped spelling reports success and does
nothing — a schema-scoped default is merged with the built-in default
rather than replacing it, and an ACL cannot record a negative, so PUBLIC
keeps `EXECUTE` and every new function still comes out with `=X`. Don't
"scope it properly" to the app schema; that silently reopens a
`SECURITY DEFINER` escalation path past the read-only tiers.

`create_app_schema` and `create_cache_table`, by contrast, are plain
psql variables gated with `\if :create_app_schema ... \endif` (a psql meta-command, evaluated by
psql itself before anything is sent to the server) — it doesn't need the
temp-table treatment since nothing inside the gated `DO $$` blocks needs
to know the flag's value at runtime; psql just skips sending those
statements at all when it's false.

That gating has one consequence worth remembering if you touch the cache
block: it lives *inside* the `create_app_schema` region, so psql skips
it entirely when that flag is false. The check that rejects
`create_cache_table=true` + `create_app_schema=false` therefore sits near
the top of the file, where both branches are live — a guard written
inside the cache block itself could never fire.
