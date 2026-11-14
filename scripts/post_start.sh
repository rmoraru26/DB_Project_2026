#!/usr/bin/env bash
# Brings a running server up to date.  `make up` runs it on the host after
# MariaDB is healthy and before the web app starts; the Windows launcher
# (frantastic.ps1) runs it inside the mariadb container.  It works the same
# for a fresh and for an older, already initialised database volume:
#
#   1. log in as the administrator.  A failed login is classified (no password
#      reached the client, password rejected, server unreachable, ...) and
#      explained; the script then stops;
#   2. apply idempotent migrations and triggers; seed rows are not re-applied
#      and existing application data is kept;
#   3. create or update the application account with the password from
#      .env (fixes ERROR 1045 for campus_app when only that password differs);
#   4. install the plugin if it is not installed.
#
# ADMINISTRATOR ACCESS.  Environment as for scripts/demo.sh:
#   MARIADB_CLIENT, DB_ADMIN_USER (default root), MYSQL_PWD and/or
#   MARIADB_ROOT_PASSWORD (scripts/mariadb_admin_auth.sh), CAMPUS_APP_PASSWORD

set -eu

cd "$(dirname "$0")/.."
. scripts/mariadb_admin_auth.sh
CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
frantastic_require_admin_password "$ADMIN_USER" post_start || exit 2

sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }

login_status=0
out=$(sql "SELECT 1;" 2>&1) || login_status=$?
if [ "$login_status" -ne 0 ]; then
    echo "post_start: cannot log in to MariaDB as '$ADMIN_USER':" >&2
    printf '    %s\n' "$out" >&2
    frantastic_explain_admin_login_failure "$out" "$login_status" "$ADMIN_USER"
    exit 3
fi

echo "-> applying idempotent migrations and refreshing campus_app (existing data is kept)"
SKIP_SEED=1 bash scripts/setup_database.sh

if [ -n "${CAMPUS_APP_PASSWORD:-}" ]; then
    echo "-> application account campus_app (password from .env)"
    bash database/app_account.sh | "${CLIENT[@]}" -u"$ADMIN_USER" --batch
fi

status=$(sql "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';")
if [ "$status" != "ACTIVE" ]; then
    echo "-> installing the campus_audit plugin"
    sql "INSTALL SONAME 'campus_audit';"
    status=$(sql "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';")
fi
echo "-> campus_audit plugin: ${status:-NOT INSTALLED}"
if [ "$status" != "ACTIVE" ]; then
    echo "post_start: the plugin is not ACTIVE; the reason is in the server log (docker compose logs mariadb)" >&2
    exit 4
fi
