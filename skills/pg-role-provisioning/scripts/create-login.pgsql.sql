-- =====================================================
-- create-login.pgsql.sql
--
-- Create (or update) ONE login role and attach it to exactly one
-- permission role. This is Part 2 of setup-new-database.pgsql.sql,
-- reduced to a single login and parameterized with psql variables
-- so it can be driven by create-login.sh.
--
-- Run as an admin/master user. Role creation and role membership
-- are cluster-wide, so this can be run against any database (the
-- driver uses the maintenance db). The per-database CONNECT and
-- schema privileges already live on the permission roles, set up
-- by setup-database-roles.pgsql.sql.
--
-- REQUIRED psql VARIABLES (pass with -v name=value):
--   role_prefix     the same root namespace passed to
--                    setup-database-roles.pgsql.sql, e.g. 'acme'.
--                    Used to build the four valid permission-role
--                    names: <role_prefix>_application,
--                    <role_prefix>_application_readonly,
--                    <role_prefix>_developer,
--                    <role_prefix>_developer_readonly.
--   login_name      the login role to create/update
--   login_password  its password (set every run, see below)
--   access_role     exactly one of the four permission roles built
--                    from role_prefix above (e.g. acme_application)
--
-- BEHAVIOUR:
--   * If the login does not exist, it is created WITH LOGIN and the
--     given password.
--   * If it already exists, its password is UPDATED (so re-running
--     with a new password actually rotates it instead of silently
--     keeping the old one).
--   * Membership is kept exclusive: the login is revoked from the
--     other three permission roles before being granted access_role.
--
-- login_name must NOT be any of the four permission role names.
-- =====================================================

-- Single-row params table, populated from the psql variables.
-- (Variables are interpolated here, OUTSIDE the dollar-quoted DO
-- block below, because psql does not substitute inside $$ ... $$.)
CREATE TEMP TABLE login_params (role_prefix text, login_name text, login_password text, access_role text);
INSERT INTO login_params (role_prefix, login_name, login_password, access_role)
VALUES (:'role_prefix', :'login_name', :'login_password', :'access_role');

DO $$
DECLARE
    v_role_prefix    text;
    v_login_name     text;
    v_login_password text;
    v_access_role    text;
    v_valid_roles    text[];
    v_other_role     text;
BEGIN
    SELECT role_prefix, login_name, login_password, access_role
    INTO v_role_prefix, v_login_name, v_login_password, v_access_role
    FROM login_params;

    IF v_role_prefix IS NULL OR v_role_prefix = '' OR v_role_prefix !~ '^[A-Za-z_][A-Za-z0-9_]*$' THEN
        RAISE EXCEPTION 'role_prefix must match ^[A-Za-z_][A-Za-z0-9_]*$ (got "%")', v_role_prefix;
    END IF;

    v_valid_roles := ARRAY[
        v_role_prefix || '_application',
        v_role_prefix || '_application_readonly',
        v_role_prefix || '_developer',
        v_role_prefix || '_developer_readonly'
    ];

    IF v_access_role IS NULL OR NOT (v_access_role = ANY (v_valid_roles)) THEN
        RAISE EXCEPTION 'access_role must be one of: % (got "%" for login "%")', array_to_string(v_valid_roles, ', '), v_access_role, v_login_name;
    END IF;

    IF v_login_name = ANY (v_valid_roles) THEN
        RAISE EXCEPTION 'login_name "%" collides with a permission role name; choose a distinct login name', v_login_name;
    END IF;

    -- Create the login role if it doesn't already exist. If it does
    -- already exist, update its password instead of leaving it
    -- untouched — otherwise re-running with a new password would
    -- silently keep the old one.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_login_name) THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', v_login_name, v_login_password);
    ELSE
        EXECUTE format('ALTER ROLE %I PASSWORD %L', v_login_name, v_login_password);
    END IF;

    -- Keep membership exclusive: drop from any of the other three
    -- permission roles before granting the requested one, so
    -- re-running to change a login's tier doesn't leave it in two
    -- roles at once. If the login isn't currently a member of a
    -- given role, the REVOKE is a no-op that prints a harmless
    -- NOTICE (safe to ignore).
    FOREACH v_other_role IN ARRAY v_valid_roles LOOP
        IF v_other_role <> v_access_role THEN
            EXECUTE format('REVOKE %I FROM %I', v_other_role, v_login_name);
        END IF;
    END LOOP;

    EXECUTE format('GRANT %I TO %I', v_access_role, v_login_name);
END $$;

-- Confirm the login role and its permission role membership
SELECT
    m.rolname     AS login_name,
    r.rolname     AS access_role,
    m.rolcanlogin AS can_login
FROM pg_auth_members am
JOIN pg_roles r ON am.roleid = r.oid
JOIN pg_roles m ON am.member = m.oid
JOIN login_params lp ON lp.login_name = m.rolname
ORDER BY m.rolname;

DROP TABLE login_params;
