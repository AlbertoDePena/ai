#!/usr/bin/env bash
#
# create-login.sh
#
# Create (or update) ONE PostgreSQL login role and attach it to a
# single permission role. Connect with a MASTER (admin) connection
# string. If the login already exists, its password is updated.
#
# Login roles and role membership are cluster-wide, so the database
# named in the connection string only needs to be one the master
# account can reach (e.g. postgres) — the per-database CONNECT and
# schema grants already live on the permission roles (set up by
# setup-database-roles.pgsql.sql / create-application-databases.sh).
#
# ---------------------------------------------------------------
# USAGE
#   ./create-login.sh -c <conninfo> -u <login_name> -r <access_role> \
#       -n <namespace>
#
# OPTIONS
#   -c <conninfo>    Master connection string (required), WITHOUT the
#                    password. Either a libpq URI or a keyword string:
#                      postgresql://user@host:5432/postgres
#                      "host=localhost port=5432 user=postgres \
#                       dbname=postgres"
#   -u <login_name>  Login role to create/update (required).
#   -r <access_role> Permission role to attach (required). One of:
#                      <namespace>_application            (r/w, application)
#                      <namespace>_application_readonly   (r/o, application)
#                      <namespace>_developer               (r/w, person)
#                      <namespace>_developer_readonly       (r/o, person)
#   -n <namespace>   Root namespace the roles above were created
#                    under (required). Must match the namespace used
#                    with create-application-databases.sh.
#   -h               Show this help.
#
# PASSWORDS  (both prompted hidden by default; neither hits argv)
#   Master (admin) password : prompted, unless PGPASSWORD is set or
#                             ~/.pgpass covers it. Blank entry defers
#                             to ~/.pgpass / the -c string.
#   New login's password    : prompted, unless LOGIN_PASSWORD is set.
#   Keep the master password OUT of the -c string.
#
# EXAMPLE
#   ./create-login.sh \
#     -c 'postgresql://admin@localhost:5432/postgres' \
#     -u acme_app_orders -r acme_application -n acme
#   # prompts for the master password, then for the new login's
#   # password, then creates/updates acme_app_orders in
#   # role acme_application
# ---------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_SQL="${SCRIPT_DIR}/create-login.pgsql.sql"

# -------- args --------
CONNINFO=""
LOGIN_NAME=""
ACCESS_ROLE=""
NAMESPACE=""

# Print the leading comment header (line 2 up to the first
# non-comment line) as help text.
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

while getopts ":c:u:r:n:h" opt; do
    case "$opt" in
        c) CONNINFO="$OPTARG" ;;
        u) LOGIN_NAME="$OPTARG" ;;
        r) ACCESS_ROLE="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "ERROR: -$OPTARG requires an argument." >&2; exit 2 ;;
        \?) echo "ERROR: unknown option -$OPTARG." >&2; exit 2 ;;
    esac
done

# -------- validate --------
if [[ -z "$CONNINFO" || -z "$LOGIN_NAME" || -z "$ACCESS_ROLE" || -z "$NAMESPACE" ]]; then
    echo "ERROR: -c <conninfo>, -u <login_name>, -r <access_role>, and -n <namespace> are all required." >&2
    usage >&2
    exit 2
fi

if [[ ! "$LOGIN_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: login name '$LOGIN_NAME' must match ^[A-Za-z_][A-Za-z0-9_]*\$." >&2
    exit 2
fi

if [[ ! "$NAMESPACE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: namespace '$NAMESPACE' must match ^[A-Za-z_][A-Za-z0-9_]*\$." >&2
    exit 2
fi

VALID_ROLES=("${NAMESPACE}_application" "${NAMESPACE}_application_readonly" "${NAMESPACE}_developer" "${NAMESPACE}_developer_readonly")

# access_role must be one of the four permission roles built from
# the namespace.
role_ok=false
for r in "${VALID_ROLES[@]}"; do [[ "$ACCESS_ROLE" == "$r" ]] && role_ok=true; done
if [[ "$role_ok" != true ]]; then
    echo "ERROR: access_role '$ACCESS_ROLE' must be one of: ${VALID_ROLES[*]} (namespace '${NAMESPACE}'; pass -n to change it)" >&2
    exit 2
fi

# login_name must not collide with a permission role name.
for r in "${VALID_ROLES[@]}"; do
    if [[ "$LOGIN_NAME" == "$r" ]]; then
        echo "ERROR: login name '$LOGIN_NAME' collides with a permission role; choose a distinct name." >&2
        exit 2
    fi
done

if [[ ! -f "$LOGIN_SQL" ]]; then
    echo "ERROR: cannot find login script at $LOGIN_SQL" >&2
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

# -------- new login's password --------
if [[ -z "${LOGIN_PASSWORD:-}" ]]; then
    read -r -s -p "Password to set for login '${LOGIN_NAME}': " LOGIN_PASSWORD
    echo
fi
if [[ -z "$LOGIN_PASSWORD" ]]; then
    echo "ERROR: login password must not be empty." >&2
    exit 2
fi

echo "==> Login       : ${LOGIN_NAME}"
echo "==> Access role : ${ACCESS_ROLE}"
echo "==> Namespace   : ${NAMESPACE}"
echo "==> Applying via the supplied master connection string..."
echo

psql -v ON_ERROR_STOP=1 --no-psqlrc "$CONNINFO" \
    -v role_prefix="$NAMESPACE" \
    -v login_name="$LOGIN_NAME" \
    -v login_password="$LOGIN_PASSWORD" \
    -v access_role="$ACCESS_ROLE" \
    -f "$LOGIN_SQL"

echo
echo "==> Done. '${LOGIN_NAME}' is a member of '${ACCESS_ROLE}' with its password set."
