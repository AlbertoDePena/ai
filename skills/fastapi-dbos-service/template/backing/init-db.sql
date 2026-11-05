-- Minimal local provisioning for this project's slice of the SHARED dev stack -
-- NOT the full role model. Production uses the pg-role-provisioning skill; this
-- is a convenience stand-in so a new checkout is turnkey.
--
-- Applied by ./setup-devstack.sh:
--     docker exec -i postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" \
--       -d postgres < backing/init-db.sql
--
-- It is NOT mounted into /docker-entrypoint-initdb.d/ any more. The Postgres
-- container belongs to the shared stack, which every repo uses, so no single
-- project gets to run scripts at its first init. Run the script instead - which
-- also means this is re-runnable rather than first-boot-only.
--
-- Every statement below is idempotent, so applying it twice is a no-op. CREATE
-- DATABASE has no IF NOT EXISTS, hence the \gexec guard: the SELECT yields the
-- DDL string only when the database is absent, and \gexec executes whatever the
-- query returned (nothing, when it already exists).
--
-- CURRENT_USER rather than a hardcoded role name, so this stays correct
-- whatever POSTGRES_USER the shared stack runs as.

-- Naming follows the pg-role-provisioning skill: <app>_main, <app>_cache
-- and <app>_dbos - every name derived from the <app> base carries a
-- suffix. This stack uses two of the three - there is no cache here.
-- Those suffixes are also what keeps this project's databases distinct from
-- every other project's in the one shared Postgres.

-- The application database - our own tables (the read model).
SELECT 'CREATE DATABASE orders_api_main'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'orders_api_main')\gexec

-- ONE DBOS system database, shared by the worker and the consumer. They are one
-- DBOS app running as two processes (same APP_NAME, same application_version),
-- which is how DBOS scales an app horizontally: either process can recover or
-- dequeue work the other started. That is only safe because both register every
-- workflow the app has - see worker.py / consumer.py. DBOS creates its own
-- tables in here on launch.
SELECT 'CREATE DATABASE orders_api_dbos'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'orders_api_dbos')\gexec

\connect orders_api_main
CREATE SCHEMA IF NOT EXISTS crane AUTHORIZATION CURRENT_USER;

-- Unqualified table names (in the app and in dbmate migrations) resolve to the
-- namespace schema through this search_path. Change `crane` here together with
-- the schema above to rename the namespace.
ALTER ROLE CURRENT_USER IN DATABASE orders_api_main SET search_path = crane, public;
