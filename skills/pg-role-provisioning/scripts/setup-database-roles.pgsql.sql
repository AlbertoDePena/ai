-- =====================================================
-- setup-database-roles.pgsql.sql
--
-- Permission roles + grants for a SINGLE database, scoped to the
-- database this script is connected to ("the current database").
--
-- This is Part 1 of setup-new-database.pgsql.sql pulled out into a
-- standalone, idempotent script so it can be applied to any number
-- of databases (e.g. an application db and its DBOS system db) by a
-- driver such as create-application-databases.sh.
--
-- Run it AGAINST the target database (psql -d <db> -f this_file),
-- as an admin/master user. Re-running it is safe: role creation is
-- guarded, and every GRANT/REVOKE is idempotent.
--
-- REQUIRED psql VARIABLES (pass with -v name=value):
--   role_prefix   root namespace for the four permission roles, e.g.
--                 'acme' produces acme_application,
--                 acme_application_readonly, acme_developer,
--                 acme_developer_readonly. Must be a valid, unquoted
--                 identifier fragment (letters/digits/underscore).
--   schema_name   application schema name, e.g. 'acme'. Any identifier
--                 works; there is no required relationship to
--                 role_prefix. Pass the SAME schema_name whether or
--                 not create_app_schema is true for this run — it
--                 identifies the schema, not whether this run
--                 creates it.
--
-- OPTIONAL psql VARIABLE:
--   create_app_schema   'true' (default) or 'false'. When false, the
--                 application schema (schema_name) is NOT created and
--                 the per-role schema/USAGE/default-privilege grants
--                 are skipped — only role creation, the public/PUBLIC
--                 lockdown, and each role's database CONNECT grant
--                 are applied. Use this for a database (e.g. a DBOS
--                 system db) where the app schema is never used, so
--                 you get the CONNECT + lockdown hardening without an
--                 empty, unused schema left behind. See
--                 create-application-databases.sh, which passes
--                 create_app_schema=true for the app db and =false
--                 for the DBOS system db (same schema_name value in
--                 both calls — it's just unused on the system db).
--
--   create_cache_table  'true' or 'false' (default). When true, the
--                 application schema also gets an UNLOGGED `cache`
--                 table (key/value/expires_at) and the DATABASE is
--                 switched to synchronous_commit = off. Requires
--                 create_app_schema=true (the table lives in the
--                 application schema) — the combination
--                 create_cache_table=true + create_app_schema=false
--                 raises. Intended for a dedicated <app>_cache
--                 database and NOTHING else: synchronous_commit is a
--                 per-database setting, so turning it off is only
--                 acceptable in a database that holds exclusively
--                 disposable data. See references/cache.md.
--
-- SCHEMA MODEL:
--   Application objects live in a dedicated schema (schema_name),
--   NOT in `public`. `public` is locked down completely (no PUBLIC
--   access, no permission-role access) so nothing can be created or
--   read there by accident. The database's search_path is pointed
--   at schema_name so application/developer sessions operate in
--   that schema by default. (Skipped entirely when create_app_schema
--   is false.)
--
--   The `dbos` schema (created and granted by the DBOS migration in
--   migrate-dbos-system.sh) is deliberately left untouched here.
--
-- WHAT THIS DOES:
--   * Creates the four cluster-wide NOLOGIN permission roles if
--     they don't already exist (no-op if another database made
--     them):
--       <role_prefix>_application            read/write, application logins
--       <role_prefix>_application_readonly   read-only,  application logins
--       <role_prefix>_developer              read/write, person logins
--       <role_prefix>_developer_readonly      read-only,  person logins
--   * Locks down `public`: revokes the implicit PUBLIC grants on the
--     database and the public schema, and strips any permission-role
--     grants a previous version of this script may have placed on
--     public.
--   * Grants each role CONNECT on THIS database. (Always — this is
--     the main reason to run this script against a database that
--     otherwise doesn't use the application schema, e.g. a DBOS
--     system db.)
--   * If create_app_schema is true (the default):
--       - Creates the schema named by schema_name.
--       - Sets the database's default search_path to
--         `<schema_name>, public`.
--       - Grants each role the appropriate privileges (plus default
--         privileges for future objects) on the schema_name schema.
--   * If create_cache_table is true (requires the above):
--       - Creates the UNLOGGED `cache` table + its expires_at index
--         in schema_name.
--       - Sets synchronous_commit = off on THIS database.
--       - Grants TRUNCATE on `cache` to the two read/write tiers
--         (the rest of its DML comes from the normal grants below).
--
-- It does NOT create any login roles — attach logins afterwards
-- with create-login.pgsql.sql / Part 2 of setup-new-database.pgsql.sql.
--
-- NOTE ON IMPLEMENTATION: psql does NOT substitute :'variables' inside
-- dollar-quoted ($$ ... $$) blocks, so role_prefix/schema_name are
-- stashed in a temp table first and read back with SELECT ... INTO
-- inside each DO block, then used with EXECUTE format(%I, ...) to
-- build every dynamic identifier safely. create_app_schema, by
-- contrast, only needs to gate which top-level statements get sent to
-- the server at all, so it stays a plain psql variable used with
-- \if / \endif (a psql meta-command, evaluated by psql itself, not by
-- the server) rather than going through the temp table.
-- =====================================================

-- Default create_app_schema to true if the caller didn't pass one, so
-- running this file directly with just role_prefix/schema_name still
-- behaves exactly as before this option existed.
\if :{?create_app_schema}
\else
\set create_app_schema true
\endif

-- create_cache_table defaults to FALSE: only a dedicated cache
-- database should get the cache table and the synchronous_commit
-- relaxation that comes with it.
\if :{?create_cache_table}
\else
\set create_cache_table false
\endif

-- The cache table lives in the application schema, so the two flags
-- can't contradict each other. This has to be checked HERE rather than
-- at the cache DDL below: that DDL sits inside the create_app_schema
-- region, so with create_app_schema=false psql would skip it -- and
-- any complaint written inside it -- entirely. Raise server-side so
-- ON_ERROR_STOP gives the caller a non-zero exit.
\if :create_cache_table
\if :create_app_schema
\else
DO $$
BEGIN
    RAISE EXCEPTION 'create_cache_table=true requires create_app_schema=true (the cache table lives in the application schema)';
END $$;
\endif
\endif

CREATE TEMP TABLE _setup_params (role_prefix text, schema_name text);
INSERT INTO _setup_params (role_prefix, schema_name) VALUES (:'role_prefix', :'schema_name');

DO $$
DECLARE
    v_role_prefix text;
BEGIN
    SELECT role_prefix INTO v_role_prefix FROM _setup_params;
    IF v_role_prefix IS NULL OR v_role_prefix = '' OR v_role_prefix !~ '^[A-Za-z_][A-Za-z0-9_]*$' THEN
        RAISE EXCEPTION 'role_prefix must match ^[A-Za-z_][A-Za-z0-9_]*$ (got "%")', v_role_prefix;
    END IF;
END $$;

DO $$
DECLARE
    v_schema text;
BEGIN
    SELECT schema_name INTO v_schema FROM _setup_params;
    IF v_schema IS NULL OR v_schema = '' OR v_schema !~ '^[A-Za-z_][A-Za-z0-9_]*$' THEN
        RAISE EXCEPTION 'schema_name must match ^[A-Za-z_][A-Za-z0-9_]*$ (got "%")', v_schema;
    END IF;
END $$;

-- ---------- permission roles (created first so the REVOKE/GRANT
--            statements below can always reference them) ----------
-- Always created, regardless of create_app_schema: they're
-- cluster-wide NOLOGIN roles, and every database wants them to exist
-- so it can grant CONNECT below.
DO $$
DECLARE
    v_role_prefix text;
    v_roles       text[];
    v_role        text;
BEGIN
    SELECT role_prefix INTO v_role_prefix FROM _setup_params;
    v_roles := ARRAY[
        v_role_prefix || '_application',
        v_role_prefix || '_application_readonly',
        v_role_prefix || '_developer',
        v_role_prefix || '_developer_readonly'
    ];
    FOREACH v_role IN ARRAY v_roles LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', v_role);
        END IF;
    END LOOP;
END $$;

-- ---------- lock down `public` ----------
-- By default Postgres grants every login CONNECT on the database and
-- USAGE/CREATE on the public schema via the implicit PUBLIC pseudo-
-- role. Revoke both so all access has to come through explicit
-- membership in one of the four permission roles instead. Always
-- applied, regardless of create_app_schema — this is the hardening
-- that's worth running even on a database with no application schema.
DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
END $$;

REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Strip anything an earlier (public-schema) version of this script may
-- have granted the permission roles on public, so migrating an
-- existing database leaves public completely closed. All no-ops on a
-- database that never had those grants. Always applied.
DO $$
DECLARE
    v_role_prefix text;
    v_roles       text[];
    v_role        text;
BEGIN
    SELECT role_prefix INTO v_role_prefix FROM _setup_params;
    v_roles := ARRAY[
        v_role_prefix || '_application',
        v_role_prefix || '_application_readonly',
        v_role_prefix || '_developer',
        v_role_prefix || '_developer_readonly'
    ];
    FOREACH v_role IN ARRAY v_roles LOOP
        EXECUTE format('REVOKE ALL ON SCHEMA public FROM %I', v_role);
        EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', v_role);
        EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %I', v_role);
        EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM %I', v_role);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM %I', v_role);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM %I', v_role);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM %I', v_role);
    END LOOP;
END $$;

-- ---------- explicit CONNECT ----------
-- Some CONNECT grant is always needed here: PUBLIC's implicit CONNECT
-- was revoked above, so without this nothing but the master account
-- could reach the database at all.
--
-- WHICH roles get it depends on create_app_schema:
--
--   * true (an application db) -- all four tiers. Application and
--     developer logins alike do their work in the application schema.
--
--   * false (a DBOS system db) -- only <prefix>_application. DBOS keeps
--     its tables in the `dbos` schema, and `dbosctl sysdb migrate
--     --app-role` grants them to exactly one role, so CONNECT for the
--     other three tiers only buys a session in which every query fails.
--     Widening this is a deliberate data-access decision, not a
--     debugging convenience: dbos.workflow_status stores serialized
--     workflow `inputs`/`output`/`request` plus the authenticated user
--     and roles, so SELECT there exposes application payloads and
--     caller identity. Expose a column-projecting VIEW instead.
--
-- The false branch also REVOKEs the other three tiers, so re-running
-- this script against a system db provisioned by an earlier version
-- (which granted all four) tightens it rather than leaving the extra
-- grants in place.
\if :create_app_schema

DO $$
DECLARE
    v_role_prefix text;
    v_roles       text[];
    v_role        text;
BEGIN
    SELECT role_prefix INTO v_role_prefix FROM _setup_params;
    v_roles := ARRAY[
        v_role_prefix || '_application',
        v_role_prefix || '_application_readonly',
        v_role_prefix || '_developer',
        v_role_prefix || '_developer_readonly'
    ];
    FOREACH v_role IN ARRAY v_roles LOOP
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), v_role);
    END LOOP;
END $$;

\else

DO $$
DECLARE
    v_role_prefix text;
    v_roles       text[];
    v_role        text;
BEGIN
    SELECT role_prefix INTO v_role_prefix FROM _setup_params;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',
                   current_database(), v_role_prefix || '_application');
    v_roles := ARRAY[
        v_role_prefix || '_application_readonly',
        v_role_prefix || '_developer',
        v_role_prefix || '_developer_readonly'
    ];
    FOREACH v_role IN ARRAY v_roles LOOP
        EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM %I', current_database(), v_role);
    END LOOP;
END $$;

\endif

\if :create_app_schema

-- ---------- the application schema (schema_name) ----------
-- Application objects live here instead of public. Owned by the
-- admin/master user running this script (the same account that runs
-- migrations), so ALTER DEFAULT PRIVILEGES below applies to the
-- objects it creates.
DO $$
DECLARE
    v_schema text;
BEGIN
    SELECT schema_name INTO v_schema FROM _setup_params;
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);
    -- Point the database at schema_name so app/developer sessions
    -- resolve unqualified objects there by default. public is kept
    -- last only so extensions installed into it stay referenceable;
    -- it grants no access on its own since public is locked down
    -- above.
    EXECUTE format('ALTER DATABASE %I SET search_path TO %I, public', current_database(), v_schema);
END $$;

-- ---------- strip PUBLIC's implicit EXECUTE in the application schema ----------
-- Postgres grants EXECUTE on every new function to PUBLIC. The public
-- schema is scrubbed of PUBLIC grants above, but the application schema
-- needs the same treatment, and for a sharper reason: a SECURITY
-- DEFINER function here runs with the *definer's* rights (the master
-- account), so a PUBLIC EXECUTE grant on one lets any role that can
-- connect -- the read-only tiers included -- perform writes it is
-- otherwise denied. That silently voids the read-only guarantee.
--
-- Invoker-rights functions are unaffected in practice (they already run
-- under the caller's table privileges), so revoking PUBLIC costs the
-- read-only tiers nothing they were entitled to.
--
-- The two read/write tiers still get EXECUTE by default further down.
-- That is deliberate but worth knowing: ALTER DEFAULT PRIVILEGES cannot
-- distinguish SECURITY DEFINER from invoker-rights functions, so a
-- SECURITY DEFINER function added to this schema is handed to those two
-- tiers automatically. Set its grants explicitly when you add one.
--
-- TWO SUBTLETIES, both load-bearing -- do not "tidy" either away:
--
-- 1. The default-privileges revoke below is deliberately GLOBAL (no
--    IN SCHEMA clause). The schema-scoped spelling,
--
--       ALTER DEFAULT PRIVILEGES IN SCHEMA x REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
--
--    reports "ALTER DEFAULT PRIVILEGES" and does NOTHING: a
--    schema-scoped entry is MERGED WITH the built-in default rather
--    than replacing it, and an ACL cannot record a negative, so PUBLIC's
--    implicit EXECUTE survives and every new function still comes out
--    with `=X`. Only the global form writes the pg_default_acl row
--    (defaclnamespace = 0) that actually suppresses it. That row is
--    per-database, so applying it here -- once per database this script
--    runs against -- is correctly scoped.
--
-- 2. It is scoped to the role that RUNS it (defaclrole), i.e. the master
--    account. That matches this model, where all DDL goes through that
--    account. If a second admin ever creates functions in this schema,
--    PUBLIC gets EXECUTE on them again and this needs re-running as
--    that role.
--
-- The REVOKE ... ON ALL FUNCTIONS statement handles functions that
-- already exist (default privileges only ever affect future objects),
-- which is what keeps re-runs effective on an established database.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

DO $$
DECLARE
    v_schema text;
BEGIN
    SELECT schema_name INTO v_schema FROM _setup_params;
    EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC', v_schema);
END $$;

-- ---------- the cache table (create_cache_table only) ----------
-- A key/value/expires_at cache, deliberately placed in a DEDICATED
-- <app>_cache database rather than alongside the application tables.
-- The reason is the database-level setting below: synchronous_commit
-- cannot be set per table, so relaxing it for cache writes means
-- relaxing it for everything in the database. A separate database is
-- what keeps "losing the last few hundred milliseconds of writes on a
-- crash" scoped to data that is disposable by definition.
--
-- Created HERE, before the per-role grant blocks, so the
-- `GRANT ... ON ALL TABLES IN SCHEMA` statements below pick it up and
-- each tier ends up with its normal DML on it. Created by this script
-- rather than by application migrations because none of the four
-- permission roles has CREATE on the schema.
\if :create_cache_table

DO $$
DECLARE
    v_schema text;
BEGIN
    SELECT schema_name INTO v_schema FROM _setup_params;

    -- UNLOGGED: the table's contents are not WAL-logged, which is the
    -- bulk of the write saving. The cost is that PostgreSQL TRUNCATES
    -- the table during crash recovery (a clean shutdown/restart keeps
    -- the rows) and that its contents never reach a physical standby,
    -- where the relation is unreadable entirely. The table definition
    -- always survives; only rows are lost. Callers must therefore
    -- treat a miss on a key they just wrote as normal.
    --
    -- fillfactor 70 leaves room for new row versions on the same page.
    -- Note what it does NOT buy here: HOT updates. A HOT update
    -- requires that no indexed column change, and refreshing an entry
    -- rewrites expires_at, which IS indexed below -- so every upsert
    -- of an existing key is a non-HOT update that adds entries to both
    -- indexes and leaves a dead tuple behind. That is why the
    -- autovacuum storage parameters are tightened too: a hot-key cache
    -- generates dead tuples far faster than the cluster defaults
    -- expect. See references/cache.md for the index-free variant that
    -- trades sweep cost for HOT updates.
    EXECUTE format($fmt$
        CREATE UNLOGGED TABLE IF NOT EXISTS %I.cache (
            key        text        PRIMARY KEY,
            value      jsonb       NOT NULL,
            expires_at timestamptz NOT NULL
        ) WITH (
            fillfactor = 70,
            autovacuum_vacuum_scale_factor = 0.02,
            autovacuum_vacuum_cost_delay = 0
        )
    $fmt$, v_schema);

    -- Serves the expiry sweep (DELETE ... WHERE expires_at <= now()),
    -- NOT reads: a lookup is a primary-key probe on `key` that filters
    -- expires_at from the fetched row.
    EXECUTE format('CREATE INDEX IF NOT EXISTS cache_expires_at_idx ON %I.cache (expires_at)', v_schema);
END $$;

-- Writes here are disposable, so don't pay for durability on them.
-- Commits lose their fsync, risking the last wal_writer_delay * 3 of
-- cache writes on a crash -- which, for a cache in its own database,
-- is a miss rather than a loss. Note this is NOT redundant with
-- UNLOGGED: an unlogged table writes no WAL for its *data*, but a
-- write transaction still assigns an XID and writes a commit record,
-- and that record is fsynced unless synchronous_commit is off.
--
-- Takes effect for NEW sessions (existing connections keep their
-- current value), and it is a *database* setting, so an
-- `ALTER ROLE ... SET synchronous_commit` on the login role outranks
-- it -- check with `\drds` if cache writes look slower than expected.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET synchronous_commit = off', current_database());
END $$;

-- TRUNCATE is the right way to flush a cache wholesale and is far
-- cheaper than a full DELETE, but it isn't part of the DML the grant
-- blocks below hand out, so grant it explicitly -- on this one table,
-- and only to the two read/write tiers.
DO $$
DECLARE
    v_role_prefix text;
    v_schema      text;
    v_role        text;
BEGIN
    SELECT role_prefix, schema_name INTO v_role_prefix, v_schema FROM _setup_params;
    FOREACH v_role IN ARRAY ARRAY[
        v_role_prefix || '_application',
        v_role_prefix || '_developer'
    ] LOOP
        EXECUTE format('GRANT TRUNCATE ON TABLE %I.cache TO %I', v_schema, v_role);
    END LOOP;
END $$;

\endif

-- ---------- <role_prefix>_application — read/write, for application logins ----------
DO $$
DECLARE
    v_role_prefix text;
    v_schema      text;
    v_role        text;
BEGIN
    SELECT role_prefix, schema_name INTO v_role_prefix, v_schema FROM _setup_params;
    v_role := v_role_prefix || '_application';

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I', v_schema, v_role);
END $$;

-- ---------- <role_prefix>_application_readonly — read-only, for application logins ----------
DO $$
DECLARE
    v_role_prefix text;
    v_schema      text;
    v_role        text;
BEGIN
    SELECT role_prefix, schema_name INTO v_role_prefix, v_schema FROM _setup_params;
    v_role := v_role_prefix || '_application_readonly';

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON SEQUENCES TO %I', v_schema, v_role);
END $$;

-- ---------- <role_prefix>_developer — read/write, for person logins ----------
DO $$
DECLARE
    v_role_prefix text;
    v_schema      text;
    v_role        text;
BEGIN
    SELECT role_prefix, schema_name INTO v_role_prefix, v_schema FROM _setup_params;
    v_role := v_role_prefix || '_developer';

    -- Deliberately no CREATE here: table/view/function/schema creation
    -- is done through the admin account, not developer logins.
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I', v_schema, v_role);
END $$;

-- ---------- <role_prefix>_developer_readonly — read-only, for person logins ----------
DO $$
DECLARE
    v_role_prefix text;
    v_schema      text;
    v_role        text;
BEGIN
    SELECT role_prefix, schema_name INTO v_role_prefix, v_schema FROM _setup_params;
    v_role := v_role_prefix || '_developer_readonly';

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I', v_schema, v_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON SEQUENCES TO %I', v_schema, v_role);
END $$;

\endif

-- Confirm the four roles exist with the expected attributes
SELECT current_database() AS database, rolname, rolcanlogin, rolinherit
FROM pg_roles, _setup_params p
WHERE rolname IN (
    p.role_prefix || '_application',
    p.role_prefix || '_application_readonly',
    p.role_prefix || '_developer',
    p.role_prefix || '_developer_readonly'
)
ORDER BY rolname;

\if :create_app_schema
-- Confirm the application schema exists and public is closed to the permission roles
SELECT current_database() AS database,
       n.nspname          AS schema,
       pg_catalog.pg_get_userbyid(n.nspowner) AS owner
FROM pg_namespace n, _setup_params p
WHERE n.nspname IN (p.schema_name, 'public')
ORDER BY n.nspname;
\else
-- create_app_schema=false: just confirm public is closed (no app schema was created here)
SELECT current_database() AS database,
       n.nspname          AS schema,
       pg_catalog.pg_get_userbyid(n.nspowner) AS owner
FROM pg_namespace n
WHERE n.nspname = 'public';
\endif

\if :create_cache_table
-- Confirm the cache table is actually UNLOGGED ('u') and that the
-- database-level synchronous_commit override is recorded.
SELECT current_database()          AS database,
       n.nspname || '.' || c.relname AS cache_table,
       c.relpersistence = 'u'      AS unlogged,
       (SELECT s.setconfig
          FROM pg_db_role_setting s
         WHERE s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
           AND s.setrole = 0)      AS database_settings
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace, _setup_params p
WHERE n.nspname = p.schema_name AND c.relname = 'cache';
\endif

DROP TABLE _setup_params;
