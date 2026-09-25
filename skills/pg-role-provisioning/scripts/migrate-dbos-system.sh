#!/usr/bin/env bash
#
# migrate-dbos-system.sh
#
# Apply the DBOS system-table migration to an application's DBOS
# system database (the <app>_dbos_system database created by
# create-application-databases.sh), using dbosctl:
#
#   github.com/dbos-inc/dbos-ctl   ->  `dbosctl sysdb migrate`
#
# dbosctl ships as a prebuilt, statically-linked binary (Linux/macOS/
# Windows, amd64/arm64) — no Go toolchain required. It's a separate
# tool from the `dbos` CLI in the dbos-transact-golang repo, but its
# `sysdb migrate` subcommand does the same job: it creates the DBOS
# system tables (in the `dbos` schema by default) and, via --app-role,
# grants the role your DBOS application runs as (a permission role,
# e.g. <namespace>_application) the privileges it needs on those
# tables — so this ties the DBOS schema into the same role model as
# the rest of these scripts. The system schema itself is shared by
# every DBOS language SDK, not Go-specific.
#
# Run it under the MASTER (admin) account: creating the schema/tables
# and granting the app role both require admin rights.
#
# ---------------------------------------------------------------
# USAGE
#   ./migrate-dbos-system.sh -c <conninfo> -n <namespace> \
#       [-r <app_role>] [-s <schema>] [-i]
#
# OPTIONS
#   -c <conninfo>    Master connection URI for the DBOS SYSTEM db,
#                    WITHOUT the password (required). Must be a
#                    postgres:// or postgresql:// URI whose user and
#                    database are the system db, e.g.:
#                      postgresql://admin@localhost:5432/orders_api_dbos_system
#   -n <namespace>   Root namespace the permission roles were created
#                    under (required). Used to validate -r and to
#                    build the default app role. Must match the
#                    namespace used with create-application-databases.sh.
#   -r <app_role>    Permission role your DBOS app runs as; granted
#                    access to the DBOS system tables (default:
#                    <namespace>_application).
#   -s <schema>      DBOS schema name (default: dbosctl's own default,
#                    `dbos`).
#   -i               Install dbosctl (prebuilt binary, no Go toolchain
#                    required) via its official install script if
#                    missing.
#   -h               Show this help.
#
# PASSWORD
#   The master password is prompted for (hidden) and injected into the
#   connection URL, which is passed to dbosctl via the
#   DBOS_SYSTEM_DATABASE_URL environment variable — so it never lands
#   in argv or shell history. Set PGPASSWORD to skip the prompt
#   (unattended). A blank entry defers to ~/.pgpass. Keep the password
#   OUT of the -c string.
#
# PREREQUISITES
#   * The <app>_dbos_system database already exists
#     (create-application-databases.sh -a <app>).
#   * dbosctl on PATH (or pass -i to install it — no Go toolchain
#     needed either way).
#
# EXAMPLE
#   ./migrate-dbos-system.sh \
#     -c 'postgresql://admin@localhost:5432/orders_api_dbos_system' \
#     -r acme_application -n acme
#   # prompts for the master password, then creates the DBOS system
#   # tables and grants acme_application access to them
# ---------------------------------------------------------------

set -euo pipefail

# -------- args --------
CONNINFO=""
APP_ROLE=""
NAMESPACE=""
SCHEMA=""
DO_INSTALL=false

DBOSCTL_INSTALL_URL="https://raw.githubusercontent.com/dbos-inc/dbos-ctl/main/install.sh"
DBOSCTL_RELEASES_URL="https://github.com/dbos-inc/dbos-ctl/releases"

# Print the leading comment header (line 2 up to the first
# non-comment line) as help text.
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

# Pure-bash percent-encoder (ASCII passwords). Encodes everything
# except the RFC 3986 unreserved set so the password is safe inside
# a URI userinfo component.
urlencode() {
    local s="$1" i c out=""
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

while getopts ":c:r:n:s:ih" opt; do
    case "$opt" in
        c) CONNINFO="$OPTARG" ;;
        r) APP_ROLE="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        s) SCHEMA="$OPTARG" ;;
        i) DO_INSTALL=true ;;
        h) usage; exit 0 ;;
        :) echo "ERROR: -$OPTARG requires an argument." >&2; exit 2 ;;
        \?) echo "ERROR: unknown option -$OPTARG." >&2; exit 2 ;;
    esac
done

# -------- validate --------
if [[ -z "$CONNINFO" || -z "$NAMESPACE" ]]; then
    echo "ERROR: -c <conninfo> and -n <namespace> are both required." >&2
    usage >&2
    exit 2
fi

if [[ "$CONNINFO" != postgres://* && "$CONNINFO" != postgresql://* ]]; then
    echo "ERROR: -c must be a postgres:// or postgresql:// URI (got '$CONNINFO')." >&2
    exit 2
fi

if [[ ! "$NAMESPACE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: namespace '$NAMESPACE' must match ^[A-Za-z_][A-Za-z0-9_]*\$." >&2
    exit 2
fi

VALID_ROLES=("${NAMESPACE}_application" "${NAMESPACE}_application_readonly" "${NAMESPACE}_developer" "${NAMESPACE}_developer_readonly")

if [[ -z "$APP_ROLE" ]]; then
    APP_ROLE="${NAMESPACE}_application"
fi

# app role must be one of the four permission roles built from the
# namespace.
role_ok=false
for r in "${VALID_ROLES[@]}"; do [[ "$APP_ROLE" == "$r" ]] && role_ok=true; done
if [[ "$role_ok" != true ]]; then
    echo "ERROR: -r app role '$APP_ROLE' must be one of: ${VALID_ROLES[*]} (namespace '${NAMESPACE}'; pass -n to change it)" >&2
    exit 2
fi

# -------- ensure dbosctl is available --------
# dbosctl ships as a prebuilt, statically-linked binary — no Go
# toolchain required, unlike the older dbos-transact-golang CLI this
# script used to drive.
if ! command -v dbosctl >/dev/null 2>&1; then
    if [[ "$DO_INSTALL" == true ]]; then
        echo "==> Installing dbosctl (prebuilt binary; no Go toolchain required)..."
        echo "==> curl -sSfL ${DBOSCTL_INSTALL_URL} | sh"
        curl -sSfL "$DBOSCTL_INSTALL_URL" | sh
        # The installer places the binary in the first writable of
        # /usr/local/bin, ~/.local/bin, or the current directory.
        # Make sure a user-local bin dir is reachable if that's where
        # it landed.
        PATH="$HOME/.local/bin:$PATH"
        export PATH
    fi
fi

if ! command -v dbosctl >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: the 'dbosctl' CLI is not on your PATH.
Install it with (no Go toolchain required — downloads a prebuilt,
checksummed, statically-linked binary):
  curl -sSfL ${DBOSCTL_INSTALL_URL} | sh
or download a release archive directly from:
  ${DBOSCTL_RELEASES_URL}
and ensure it's on your PATH — or re-run this script with -i to
install it automatically.
EOF
    exit 1
fi

# -------- master password --------
# Take from PGPASSWORD (unattended) or a hidden prompt. Inject it into
# the URI userinfo and hand the whole thing to dbosctl via an env var,
# so no password appears in argv. Blank => leave the URI password-less
# and let libpq/pgx fall back to ~/.pgpass.
if [[ -n "${PGPASSWORD:-}" ]]; then
    _pw="$PGPASSWORD"
else
    read -r -s -p "Master password (blank = use ~/.pgpass): " _pw
    echo
fi

if [[ -n "$_pw" ]]; then
    # Split "scheme://" from the rest, then split userinfo@hostpart.
    proto="${CONNINFO%%://*}://"
    rest="${CONNINFO#*://}"
    if [[ "$rest" != *"@"* ]]; then
        echo "ERROR: -c URI must include a user, e.g. postgresql://admin@host:5432/db" >&2
        exit 2
    fi
    userinfo="${rest%%@*}"
    hostpart="${rest#*@}"
    if [[ "$userinfo" == *:* ]]; then
        echo "ERROR: -c URI already contains a password; supply it WITHOUT one (it is prompted)." >&2
        exit 2
    fi
    DBOS_SYSTEM_DATABASE_URL="${proto}${userinfo}:$(urlencode "$_pw")@${hostpart}"
else
    DBOS_SYSTEM_DATABASE_URL="$CONNINFO"
fi
export DBOS_SYSTEM_DATABASE_URL
unset _pw

# -------- run the migration --------
# dbosctl's sysdb commands take a database URL directly (from
# $DBOS_SYSTEM_DATABASE_URL here) rather than a profile — they talk to
# Postgres, not Conductor, so no login/profile setup is needed.
migrate_args=(sysdb migrate --app-role "$APP_ROLE")
if [[ -n "$SCHEMA" ]]; then
    migrate_args+=(--schema "$SCHEMA")
fi

echo "==> System db     : ${CONNINFO##*@}"   # host:port/db, no userinfo
echo "==> Namespace     : ${NAMESPACE}"
echo "==> App role      : ${APP_ROLE}"
echo "==> Schema        : ${SCHEMA:-dbos (dbosctl default)}"
echo "==> Running: dbosctl ${migrate_args[*]}"
echo

dbosctl "${migrate_args[@]}"

echo
echo "==> Done. DBOS system tables migrated; '${APP_ROLE}' granted access."
