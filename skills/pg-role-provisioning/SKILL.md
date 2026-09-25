---
name: pg-role-provisioning
description: Provision PostgreSQL application databases, a four-tier permission-role model (read/write and read-only roles for both applications and developers), login roles, and DBOS system-database migrations — all built on a namespace the caller supplies (no hard-coded role prefix or schema name). Use this skill whenever the user wants to set up new application/DBOS databases, create or rotate PostgreSQL login roles tied to a permission-role model, or wants a role-prefix/schema naming convention parameterized around their own namespace (e.g. "acme", "orders", their company name). Trigger on requests like "set up a new database for my app with roles", "create a postgres login for this service", "migrate the DBOS system database", or "give me a role-based Postgres provisioning setup with my own namespace".
---

# PostgreSQL role-based provisioning

This skill bundles a small toolkit of three shell scripts + two SQL
files that provision PostgreSQL databases under a **four-role
permission model**: `<namespace>_application`,
`<namespace>_application_readonly`, `<namespace>_developer`,
`<namespace>_developer_readonly`, all granted on a dedicated application
schema (default: same name as `<namespace>`) instead of `public`.

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
- Adding a login (service account or developer) to an existing setup.
- Running the DBOS system-table migration for a DBOS-backed app.
- Any project that wants this role-based permission model under its own
  namespace — just pass `-n <their namespace>` (and optionally `-s`),
  no script editing needed.

## Files

```
scripts/
  create-application-databases.sh   # create <app> + <app>_dbos_system dbs, apply roles to both
  setup-database-roles.pgsql.sql    # role/grant logic for ONE database (invoked by the script above)
  create-login.sh                   # create/update one login, attach to one permission role
  create-login.pgsql.sql            # SQL behind create-login.sh
  migrate-dbos-system.sh            # run `dbosctl sysdb migrate`, grant the app role access to DBOS tables
references/
  README.md                         # full documentation: role model, all options, workflow, gotchas
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

# 1. Create the app db + its DBOS system db, apply the role model to both
./create-application-databases.sh -c "$CONN" -a orders_api -n "$NS"

# 2. Migrate the DBOS system database
./migrate-dbos-system.sh \
  -c 'postgresql://admin@localhost:5432/orders_api_dbos_system' \
  -r "${NS}_application" -n "$NS" -i

# 3. Attach a read/write service-account login for the app
./create-login.sh -c "$CONN" -u "${NS}_app_orders" -r "${NS}_application" -n "$NS"

# 4. Attach a read-only login for a developer
./create-login.sh -c "$CONN" -u "${NS}_jdoe" -r "${NS}_developer_readonly" -n "$NS"
```

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
sets it to `true` for the app db and `false` for the `<app>_dbos_system`
db, via `\set create_app_schema ...` before each `\i` call — the same
`schema_name` value is passed once, up front, for both databases; the
flag just controls whether that run actually creates the schema.

When `false`, role creation, the `public`/`PUBLIC` lockdown, and each
role's `CONNECT` grant still happen (that's the actual reason to run
this script against the DBOS system db at all — `dbosctl sysdb
migrate` never does that hardening); only the application-schema
creation and its schema-level grants are skipped. This avoids leaving a
pointless, empty app schema sitting in the DBOS system database, since
DBOS puts its real tables in its own `dbos` schema instead.

If asked to change this default, or to run the roles script standalone,
remember: omitting `-v create_app_schema=...` behaves as `true` (full
backward-compatible behavior).

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

`create_app_schema`, by contrast, is a plain psql variable gated with
`\if :create_app_schema ... \endif` (a psql meta-command, evaluated by
psql itself before anything is sent to the server) — it doesn't need the
temp-table treatment since nothing inside the gated `DO $$` blocks needs
to know the flag's value at runtime; psql just skips sending those
statements at all when it's false.
