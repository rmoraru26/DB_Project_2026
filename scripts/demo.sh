#!/usr/bin/env bash
# End-to-end demonstration: install/verify the plugin, cause audited events,
# import the plugin log and show what an administrator sees.
#
# ADMINISTRATOR ACCESS (INSTALL SONAME, SET GLOBAL, FILE privilege).
#
# Docker:
#   MYSQL_PWD=<root password from .env> \
#   MARIADB_CLIENT="docker compose exec -T -e MYSQL_PWD mariadb mariadb" bash scripts/demo.sh
# Inside the mariadb container (Windows launcher): no variables needed; the
# service's MARIADB_ROOT_PASSWORD is used (scripts/mariadb_admin_auth.sh).
# Native server:
#   MYSQL_PWD=... MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" bash scripts/demo.sh

set -eu

. "$(dirname "${BASH_SOURCE[0]}")/mariadb_admin_auth.sh"
CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
frantastic_require_admin_password "$ADMIN_USER" demo || exit 2

sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --table "${@:2}"; }

step() { printf '\n=== %s\n' "$1"; }

step "Server version"
sql "SELECT VERSION() AS version, @@version_compile_os AS os, @@plugin_maturity AS plugin_maturity;"

step "1. Install the plugin (no-op if it is already installed)"
sql "INSTALL SONAME 'campus_audit';"
sql "SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY, PLUGIN_MATURITY, PLUGIN_AUTH_VERSION
     FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';"
sql "SHOW GLOBAL VARIABLES LIKE 'campus\_audit\_%';"

step "2. Cause events: an application booking, a rejected statement, a failed login"
DAY=$(( (RANDOM % 900) + 30 ))
sql "USE university_resources;
     SET @app_user_id = (SELECT user_id FROM users WHERE email = 'alice.student@example.edu');
     INSERT INTO bookings (user_id, room_id, start_time, end_time)
     SELECT @app_user_id, room_id, CURRENT_DATE + INTERVAL $DAY DAY + INTERVAL 15 HOUR,
            CURRENT_DATE + INTERVAL $DAY DAY + INTERVAL 16 HOUR
     FROM rooms WHERE name = 'Room 201';
     SELECT name, capacity FROM rooms ORDER BY room_id LIMIT 3;"
printf '%s\n' "INSERT INTO university_resources.rooms (name, capacity) VALUES ('Broken room', 0);" \
    | "${CLIENT[@]}" -u"$ADMIN_USER" 2>&1 | sed 's/^/   (expected) /' || true
printf '%s\n' "SELECT 1;" | MYSQL_PWD=not-the-password "${CLIENT[@]}" -unobody_demo 2>&1 \
    | sed 's/^/   (expected) /' || true

step "3. Raw JSON lines written by the plugin (last 6)"
sql "SELECT RIGHT(LOAD_FILE(@@GLOBAL.campus_audit_file_path), 2500) AS tail_of_log\G" --vertical

step "4. Import into campus_audit.plugin_events"
sql "CALL campus_audit.import_plugin_log(@@GLOBAL.campus_audit_file_path);"

step "5. Table access with statement outcome (campus_audit.v_table_activity)"
sql "SELECT event_time, event_type, table_name, db_user, connection_id, query_id,
            statement_error_code AS err, LEFT(sql_digest, 70) AS sql_digest
     FROM campus_audit.v_table_activity ORDER BY event_time DESC LIMIT 6;"

step "6. Row changes (triggers) joined with the plugin's statement (v_row_change_history)"
sql "SELECT event_id, entity_table, action, entity_id, application_user_id AS app_user,
            event_source, plugin_query_id, LEFT(sql_digest, 60) AS sql_digest
     FROM campus_audit.v_row_change_history ORDER BY event_id DESC LIMIT 3;"

step "7. Failed logins"
sql "SELECT event_time, attempted_user, client_host, error_code FROM campus_audit.v_failed_logins
     ORDER BY event_time DESC LIMIT 3;"

step "8. Plugin health counters"
sql "SHOW GLOBAL STATUS LIKE 'campus\_audit\_%';"
