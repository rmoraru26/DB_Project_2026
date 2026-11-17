#!/usr/bin/env bash
# Read-only diagnosis of the Docker setup:  make doctor
#
# Checks, in the order a failure would cascade:
#   .env  ->  containers  ->  root login  ->  campus_app login (through the
#   web app's /healthz)  ->  plugin ACTIVE  ->  Audit Lab objects  ->
#   row-history triggers  ->  generated local accounts
# and says what to do for each failure.  It changes nothing and never prints
# a password.  Exit status 0 when every check passed.
#
# "Healthy" containers do not imply working logins: the MariaDB healthcheck
# (healthcheck.sh) logs in with its own account, stored inside the volume, so it
# passes even when the root and campus_app passwords in .env are wrong.  That
# is why this script tests the two accounts the project actually uses.

set -u

cd "$(dirname "$0")/.."
. scripts/mariadb_admin_auth.sh
COMPOSE=(${COMPOSE:-docker compose})
FAILED=0
ok()   { printf '  [ OK ] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$1"; }
hint() { printf '         %s\n' "$@"; }

echo "campus_audit doctor"

# ------------------------------------------------------------------ .env
if [ ! -f .env ]; then
    bad ".env is missing"
    hint "create it with: bash scripts/make_env.sh   (then: make up)"
    exit 1
fi
if grep -q $'\r' .env; then
    bad ".env has Windows (CRLF) line endings; values would carry a hidden \\r"
    hint "fix: sed -i 's/\\r\$//' .env"
fi
set -a; . ./.env 2>/dev/null; set +a
missing=""
for v in MARIADB_ROOT_PASSWORD CAMPUS_APP_PASSWORD SECRET_KEY; do
    [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
    bad ".env lacks:$missing"
else
    ok ".env defines MARIADB_ROOT_PASSWORD, CAMPUS_APP_PASSWORD and SECRET_KEY"
fi
if [ -n "${DB_PASSWORD:-}" ] && [ "${DB_PASSWORD}" != "${CAMPUS_APP_PASSWORD:-}" ]; then
    warn "DB_PASSWORD differs from CAMPUS_APP_PASSWORD (only matters for running the app outside Docker)"
fi

# ------------------------------------------------------------------ containers
project=${COMPOSE_PROJECT_NAME:-campus-audit}
if ! command -v docker >/dev/null 2>&1; then
    bad "docker is not installed or not on PATH"
    exit 1
fi
ps_out=$("${COMPOSE[@]}" ps --format '{{.Service}} {{.State}} {{.Health}}' 2>&1) || ps_out=""
db_state=$(printf '%s\n' "$ps_out" | awk '$1=="mariadb"{print $2" "$3}')
web_state=$(printf '%s\n' "$ps_out" | awk '$1=="web"{print $2" "$3}')
[ -n "$db_state" ] && ok "mariadb container: $db_state" || bad "mariadb container is not running (make up)"
[ -n "$web_state" ] && ok "web container: $web_state" || warn "web container is not running"

volume="${project}_mariadb-data"
if created=$(docker volume inspect -f '{{.CreatedAt}}' "$volume" 2>/dev/null); then
    env_time=$(date -r .env '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo "?")
    ok "database volume $volume created $created; .env last changed $env_time"
    hint "a volume older than .env keeps the passwords of the .env that existed when it was created"
fi
[ -z "$db_state" ] && { echo; echo "$FAILED check(s) failed."; exit 1; }

# ------------------------------------------------------------------ root
root_status=0
root_out=$(MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-}" "${COMPOSE[@]}" exec -T -e MYSQL_PWD mariadb \
           mariadb -uroot --batch --skip-column-names -e "SELECT VERSION();" 2>&1) || root_status=$?
if [ "$root_status" -eq 0 ]; then
    ok "root login with the password from .env (server $root_out)"
    ROOT_OK=1
else
    ROOT_OK=0
    bad "root login with the password from .env: ${root_out##*$'\n'}"
    # The explanation depends on what failed: no password sent, password
    # rejected (typically an older volume), server unreachable, ...
    frantastic_explain_admin_login_failure "$root_out" "$root_status" root 2>&1 | sed -e '/^$/d' -e 's/^/         /'
fi

# ------------------------------------------------------------------ campus_app through the web app
if [ -n "$web_state" ]; then
    health=$("${COMPOSE[@]}" exec -T web python -c '
import json, sys, urllib.error, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:5000/healthz", timeout=5) as r:
        body = r.read().decode()
except urllib.error.HTTPError as e:
    body = e.read().decode()
except OSError as e:
    body = json.dumps({"status": "error", "detail": str(e)})
print(body)' 2>&1)
    if printf '%s' "$health" | grep -q '"status": *"ok"'; then
        ok "web app logs in to MariaDB as campus_app (/healthz)"
    else
        bad "web app cannot use the database: $health"
        if printf '%s' "$health" | grep -q '1045'; then
            # Compared, never printed.
            web_pw=$("${COMPOSE[@]}" exec -T web printenv DB_PASSWORD 2>/dev/null)
            if [ "$web_pw" != "${CAMPUS_APP_PASSWORD:-}" ]; then
                hint "The web container runs with another campus_app password than .env: it was started" \
                     "before .env changed, or with a CAMPUS_APP_PASSWORD exported in the shell, which" \
                     "Docker Compose prefers over .env.  Fix: unset CAMPUS_APP_PASSWORD, then make up."
            elif [ "$ROOT_OK" = 1 ]; then
                hint "Only campus_app's password differs: make up re-creates the account from .env."
            else
                hint "Same cause as the root failure above: make repair-credentials (keeps data)."
            fi
            unset web_pw
        fi
    fi
fi

# ------------------------------------------------------------------ plugin and lab (needs root)
if [ "$ROOT_OK" = 1 ]; then
    q() { MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "${COMPOSE[@]}" exec -T -e MYSQL_PWD mariadb \
          mariadb -uroot --batch --skip-column-names -e "$1" 2>&1; }
    plugin=$(q "SELECT CONCAT(PLUGIN_STATUS, ' / state ', (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_STATE')) FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';")
    case "$plugin" in
        "ACTIVE / state ACTIVE") ok "campus_audit plugin: $plugin" ;;
        "") bad "campus_audit plugin is not installed"; hint "make up installs it (or: make demo)" ;;
        *) bad "campus_audit plugin: $plugin"; hint "see Campus_audit_last_error: make sql, then SHOW GLOBAL STATUS LIKE 'campus_audit%';" ;;
    esac
    lab=$(q "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='campus_audit' AND ROUTINE_NAME='import_current_log';")
    if [ "$lab" = "1" ]; then
        ok "Audit Lab objects present (migration 003)"
    else
        bad "Audit Lab objects missing: the volume predates migration 003"
        hint "make migrate   (or make up, which applies it automatically; data is kept)"
    fi

    # Row-history triggers.  Both audit trails depend on them, and with the
    # plugin's default settings DROP TRIGGER leaves no plugin record (the
    # server reports it as read access; docs/experiments.md), so their
    # presence is checked here against database/triggers.sql.
    if [ -f database/triggers.sql ]; then
        expected=$(tr -d '\r' < database/triggers.sql | sed -n 's/^CREATE OR REPLACE TRIGGER \([A-Za-z0-9_]*\).*/\1/p' | sort)
        present=$(q "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='university_resources';" | tr -d '\r' | sort)
        missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$present") | tr '\n' ' ')
        if [ -n "$expected" ] && [ -z "${missing// /}" ]; then
            ok "row-history triggers present ($(printf '%s\n' "$expected" | wc -l | tr -d ' ') of database/triggers.sql)"
        elif [ -n "$expected" ]; then
            bad "row-history triggers missing: $missing"
            hint "make migrate re-creates them (data is kept).  Changes made while a trigger was" \
                 "missing have no row history; the plugin log still shows the statements."
        fi
    fi

    # The generated local accounts (never their passwords).
    demo=$(q "SELECT COALESCE((SELECT CONCAT(role, IF(is_active, '', ' (deactivated)')) FROM university_resources.users WHERE email='demo.student@frantastic.local'), 'missing');")
    case "$demo" in
        student)
            if [ -f .demo-credentials ]; then ok "demo student account present (role student); credential file .demo-credentials present"
            else warn "demo student account present, but .demo-credentials is not on this machine"
                 hint "nothing is wrong with the database; make reset-demo issues a new demo password"; fi ;;
        missing) warn "demo student account not created yet"; hint "make up creates it" ;;
        *) warn "demo student account: $demo" ;;
    esac
    legacy=$(q "SELECT COUNT(*) FROM university_resources.users WHERE email IN ('alice.student@example.edu','bob.student@example.edu','dana.admin@example.edu') AND password_hash REGEXP '^(scrypt|pbkdf2):';")
    if [ "$legacy" != "0" ] && printf '%s' "$legacy" | grep -Eq '^[0-9]+$'; then
        warn "$legacy seeded identity/identities (alice, bob, dana @example.edu) have a real password hash"
        hint "This database was created by a version that published a shared demo password, or the" \
             "password was set by hand.  The current seed stores the placeholder TEST_HASH_NOT_FOR_LOGIN." \
             "To disable these logins:  make sql, then" \
             "  UPDATE university_resources.users SET password_hash = 'TEST_HASH_NOT_FOR_LOGIN'" \
             "   WHERE email IN ('alice.student@example.edu','bob.student@example.edu','dana.admin@example.edu');"
    fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All checks passed. Web app: http://127.0.0.1:${WEB_PORT:-5000}  (guided tour: /lab)"
else
    echo "$FAILED check(s) failed."
fi
[ "$FAILED" -eq 0 ]
