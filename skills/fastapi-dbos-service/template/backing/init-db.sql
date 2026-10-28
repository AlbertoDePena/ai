-- Minimal local provisioning for the compose stack - NOT the full role model.
-- Production uses the pg-role-provisioning skill; this is a convenience stand-in
-- so `docker compose up` is turnkey.
--
-- Mounted into /docker-entrypoint-initdb.d/ and run once, as POSTGRES_USER
-- against POSTGRES_DB, on FIRST init of an empty pgdata volume. It does not run
-- against a volume that already has data - see README ("the init script already
-- ran") for how to recover.
--
-- CURRENT_USER rather than a hardcoded role name, so this stays correct if
-- POSTGRES_USER changes in .env. (initdb runs this as POSTGRES_USER.)

-- Naming follows the pg-role-provisioning skill: <app>_main, <app>_cache
-- and <app>_dbos - every name derived from the <app> base carries a
-- suffix. This stack uses two of the three - there is no cache here.

-- The application database - our own tables (the read model).
CREATE DATABASE orders_api_main;

-- ONE DBOS system database, shared by the worker and the consumer. They are one
-- DBOS app running as two processes (same APP_NAME, same application_version),
-- which is how DBOS scales an app horizontally: either process can recover or
-- dequeue work the other started. That is only safe because both register every
-- workflow the app has - see worker.py / consumer.py. DBOS creates its own
-- tables in here on launch.
CREATE DATABASE orders_api_dbos;

\connect orders_api_main
CREATE SCHEMA IF NOT EXISTS crane AUTHORIZATION CURRENT_USER;

-- Unqualified table names (in the app and in dbmate migrations) resolve to the
-- namespace schema through this search_path. Change `crane` here together with
-- the schema above to rename the namespace.
ALTER ROLE CURRENT_USER IN DATABASE orders_api_main SET search_path = crane, public;
