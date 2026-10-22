#!/usr/bin/env bash
#
# create-application-databases.sh
#
# Provision a new application's PostgreSQL databases:
#   1. <app>              -- the application database
#   2. <app>_cache        -- its key/value cache database (skip with -k)
#   3. <app>_dbos         -- its DBOS system database
#
# NOTE: <app>_dbos is deliberately SHORTER than the name DBOS derives
# from the application database on its own, so the application must be
# told where its system database is -- set DBOS_SYSTEM_DATABASE_URL (or
# the equivalent field in its DBOS config) to this database explicitly.
# The provisioning side is unaffected: migrate-dbos-system.sh and
# `dbosctl sysdb migrate` both take the system database URL as an
# argument and never derive it.
#
# All three are created on the connected server and then have the
# <namespace>_* permission roles applied via
# setup-database-roles.pgsql.sql (Part 1 of setup-new-database):
#   * On <app>: full treatment — locks down the public schema,
#     creates the application schema, and grants the <namespace>_*
#     roles on it. The app operates in the context of that schema.
#   * On <app>_cache: the full treatment PLUS an UNLOGGED `cache`
#     table (key/value/expires_at) in the application schema and
#     synchronous_commit = off on the database
#     (create_cache_table=true). It is a separate database precisely
#     because synchronous_commit is a per-database setting: keeping
#     the cache out of <app> is what confines that relaxed durability
#     to data that is disposable by definition. See
#     references/cache.md for the table, its query patterns, and its
#     trade-offs.
#   * On <app>_dbos: the same public/PUBLIC lockdown and
#     database CONNECT grants, but WITHOUT creating the application
#     schema there (create_app_schema=false) — DBOS keeps its own
#     tables in a separate `dbos` schema (via migrate-dbos-system.sh),
#     so an app schema on the system db would just sit there unused.
#     The same schema name (-s) is still passed for every database;
#     it's simply not acted on for the system db.
#
# You connect with a full MASTER (admin) connection string. That
# account must be able to CREATE DATABASE and CREATE ROLE. The
# script connects once to the database named in the connection
# string (a maintenance db such as 'postgres'), creates the two
# databases from there, then uses \c to hop into each new database
# (reusing the same credentials) to apply the roles/grants.
#
# ---------------------------------------------------------------
# USAGE
#   ./create-application-databases.sh -c <conninfo> -a <app_name> \
#       -n <namespace> [-s <schema>] [-k]
#
# OPTIONS
#   -c <conninfo>    Master connection string (required), WITHOUT the
#                    password. Either a libpq URI or a keyword string,
#                    pointing at a maintenance db (e.g. postgres):
#                      postgresql://user@host:5432/postgres
#                      "host=localhost port=5432 user=postgres \
#                       dbname=postgres"
#   -a <app_name>    Application db name (required). The DBOS system
#                    db is derived as <app_name>_dbos.
#   -n <namespace>   Root namespace for the four permission roles
#                    (required). Produces <namespace>_application,
#                    <namespace>_application_readonly,
#                    <namespace>_developer, <namespace>_developer_readonly.
#                    Must match ^[A-Za-z_][A-Za-z0-9_]*$.
#   -s <schema>      Application schema name (default: same as
#                    <namespace>). Must match ^[A-Za-z_][A-Za-z0-9_]*$.
#   -k               Skip the <app>_cache database. Use it when the
#                    app has no cache, or caches somewhere else; the
#                    db is otherwise created even if unused, since an
#                    empty cache table costs nothing.
#   -h               Show this help.
#
# PASSWORD
#   The master password is prompted for (hidden) so it never lands
#   in argv or shell history. To run unattended, set PGPASSWORD in
#   the environment (skips the prompt) or use ~/.pgpass. Leaving the
#   prompt blank defers to ~/.pgpass / the -c string / psql's own
#   prompt. Keep the password OUT of the -c string.
#
# EXAMPLE
#   ./create-application-databases.sh \
#     -c 'postgresql://admin@localhost:5432/postgres' \
#     -a orders_api -n acme
#   # prompts for admin's password, then creates databases:
#   #   orders_api, orders_api_cache and orders_api_dbos,
#   #   with permission roles
#   #   acme_application, acme_application_readonly, acme_developer,
#   #   acme_developer_readonly granted on schema "acme"
# ---------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_SQL="${SCRIPT_DIR}/setup-database-roles.pgsql.sql"

# -------- args --------
CONNINFO=""
APP_DB=""
NAMESPACE=""
SCHEMA_NAME=""
CREATE_CACHE_DB=true

# Print the leading comment header (line 2 up to the first
# non-comment line) as help text.
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

while getopts ":c:a:n:s:kh" opt; do
    case "$opt" in
        c) CONNINFO="$OPTARG" ;;
        a) APP_DB="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        s) SCHEMA_NAME="$OPTARG" ;;
        k) CREATE_CACHE_DB=false ;;
        h) usage; exit 0 ;;
        :) echo "ERROR: -$OPTARG requires an argument." >&2; exit 2 ;;
        \?) echo "ERROR: unknown option -$OPTARG." >&2; exit 2 ;;
    esac
done

# -------- validate --------
if [[ -z "$CONNINFO" || -z "$APP_DB" || -z "$NAMESPACE" ]]; then
    echo "ERROR: -c <conninfo>, -a <app_name>, and -n <namespace> are all required." >&2
    usage >&2
    exit 2
fi

# Database identifiers, the namespace, and the schema name are
# interpolated into DDL, \c, and psql -v values below; keep them all
# to a safe, predictable shape.
if [[ ! "$APP_DB" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: app name '$APP_DB' must match ^[A-Za-z_][A-Za-z0-9_]*\$." >&2
    exit 2
fi

if [[ ! "$NAMESPACE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: namespace '$NAMESPACE' must match ^[A-Za-z_][A-Za-z0-9_]*\$." >&2
    exit 2
fi

if [[ -z "$SCHEMA_NAME" ]]; then
    SCHEMA_NAME="$NAMESPACE"
fi
if [[ ! "$SCHEMA_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: schema name '$SCHEMA_NAME' must match ^[A-Za-z_][A-Za-z0-9_]*\$." >&2
    exit 2
fi

CACHE_DB="${APP_DB}_cache"
SYS_DB="${APP_DB}_dbos"

if [[ ! -f "$ROLES_SQL" ]]; then
    echo "ERROR: cannot find roles script at $ROLES_SQL" >&2
    exit 1
fi

# -------- master password --------
# Prompt (hidden) by default. Skip if PGPASSWORD is already set
# (unattended runs). A blank entry exports nothing, so libpq falls
# back to ~/.pgpass, a password in the -c string, or its own prompt.
if [[ -z "${PGPASSWORD:-}" ]]; then
    read -r -s -p "Master password (blank = use ~/.pgpass or -c string): " _master_pw
    echo
    if [[ -n "$_master_pw" ]]; then
        export PGPASSWORD="$_master_pw"
    fi
    unset _master_pw
fi

echo "==> Application db : ${APP_DB}"
if [[ "$CREATE_CACHE_DB" == true ]]; then
    echo "==> Cache db       : ${CACHE_DB} (unlogged cache table, synchronous_commit=off)"
else
    echo "==> Cache db       : skipped (-k)"
fi
echo "==> DBOS system db : ${SYS_DB}"
echo "==> Role namespace : ${NAMESPACE} (${NAMESPACE}_application, ${NAMESPACE}_application_readonly, ${NAMESPACE}_developer, ${NAMESPACE}_developer_readonly)"
echo "==> App schema     : ${SCHEMA_NAME}"
echo "==> Provisioning via the supplied master connection string..."
echo

# The cache database is optional (-k), so its two pieces -- the
# CREATE DATABASE and the roles/cache-table application -- are built as
# fragments spliced into the single psql session below, keeping it to
# one connection regardless. Both are empty when -k was passed.
# Unquoted heredocs, so ${...} expands here while psql's own \-commands
# pass through untouched (as in the main heredoc).
CACHE_CREATE_SQL=""
CACHE_SETUP_SQL=""
if [[ "$CREATE_CACHE_DB" == true ]]; then
    CACHE_CREATE_SQL=$(cat <<CACHE_CREATE
\echo '==> Ensuring database "${CACHE_DB}" exists...'
SELECT format('CREATE DATABASE %I', '${CACHE_DB}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${CACHE_DB}')
\gexec
CACHE_CREATE
)
    CACHE_SETUP_SQL=$(cat <<CACHE_SETUP
\echo '==> Applying ${NAMESPACE}_* roles + ${SCHEMA_NAME} schema + unlogged cache table to "${CACHE_DB}"...'
\c ${CACHE_DB}
\set create_app_schema true
\set create_cache_table true
\i ${ROLES_SQL}
CACHE_SETUP
)
fi

# Single session against the maintenance db in the connection string.
#   * CREATE DATABASE can't run in a txn or as IF NOT EXISTS, so it's
#     generated with \gexec only when the db is absent.
#   * \c <db> reconnects to each new db reusing the same credentials.
#   * role_prefix / schema_name are passed in as psql -v variables so
#     the \i'd roles script (invoked in the same session) can read
#     them back with :'role_prefix' / :'schema_name'.
#   * \i applies the permission roles/grants inside that db.
# App/sys names are validated above, so interpolating them here is safe.
psql -v ON_ERROR_STOP=1 --no-psqlrc \
    -v role_prefix="$NAMESPACE" \
    -v schema_name="$SCHEMA_NAME" \
    "$CONNINFO" <<SQL
\echo '==> Ensuring database "${APP_DB}" exists...'
SELECT format('CREATE DATABASE %I', '${APP_DB}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${APP_DB}')
\gexec
${CACHE_CREATE_SQL}
\echo '==> Ensuring database "${SYS_DB}" exists...'
SELECT format('CREATE DATABASE %I', '${SYS_DB}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${SYS_DB}')
\gexec

\echo '==> Applying ${NAMESPACE}_* roles + ${SCHEMA_NAME} schema to "${APP_DB}"...'
\c ${APP_DB}
\set create_app_schema true
\set create_cache_table false
\i ${ROLES_SQL}

${CACHE_SETUP_SQL}

\echo '==> Applying ${NAMESPACE}_* roles (public/PUBLIC lockdown + CONNECT only, no app schema) to "${SYS_DB}"...'
\c ${SYS_DB}
\set create_app_schema false
\set create_cache_table false
\i ${ROLES_SQL}
SQL

echo
if [[ "$CREATE_CACHE_DB" == true ]]; then
    echo "==> Done. Created/verified '${APP_DB}', '${CACHE_DB}' and '${SYS_DB}' with ${NAMESPACE}_* roles."
    echo "    The cache table is ${SCHEMA_NAME}.cache in '${CACHE_DB}' -- a SEPARATE"
    echo "    connection/pool from '${APP_DB}'; see references/cache.md."
else
    echo "==> Done. Created/verified '${APP_DB}' and '${SYS_DB}' with ${NAMESPACE}_* roles."
fi
echo "    Attach logins with create-login.sh -n ${NAMESPACE} against this server."
