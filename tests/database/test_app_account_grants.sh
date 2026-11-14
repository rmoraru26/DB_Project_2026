#!/usr/bin/env bash
# Checks the least-privilege grants of database/app_account.sh on the server:
#   1. a throwaway account receives exactly the SQL database/app_account.sh
#      prints for campus_app (only the account name is changed), first on a
#      fresh account, then on one that carries an old table-wide INSERT/UPDATE
#      on users, then once more; each time its privileges must equal the
#      expected list exactly;
#   2. logged in as that account: registration's column INSERT and the
#      account-settings UPDATE of full_name/password_hash work; role,
#      is_active and email updates, writes to audit_events and
#      campus_audit.plugin_events and DELETE on loans are refused;
#      DELETE on audit_lab_notes and EXECUTE on import_current_log() work;
#   3. the installed campus_app account (if present) has the same privileges.
# Statements that would change rows either match no row or are rolled back.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/test_app_account_grants.sh
#
# ADMINISTRATOR ACCESS (creates and drops one throwaway account with a random
# password that is never printed).

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
TEST_USER=fr_grant_test_$$
TEST_PW=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }
sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }
sql_test() { printf '%s\n' "$1" | MYSQL_PWD="$TEST_PW" "${CLIENT[@]}" -u"$TEST_USER" --batch --skip-column-names; }

cleanup() { sql "DROP USER IF EXISTS '$TEST_USER'@'%';" >/dev/null 2>&1; }
trap cleanup EXIT

# The account SQL for the throwaway account.  The decoy audit_lab_intruder
# line is left out so the test does not touch that shared account.
apply_account_sql() {
    env -u CAMPUS_APP_HOST CAMPUS_APP_PASSWORD="$TEST_PW" bash database/app_account.sh \
        | sed -e "s/'campus_app'/'$TEST_USER'/g" -e '/audit_lab_intruder/d' \
        | "${CLIENT[@]}" -u"$ADMIN_USER" --batch
}

privileges() {   # privileges <user> <host>: one line per privilege, sorted
    sql "SET @g = CONCAT(QUOTE('$1'), '@', QUOTE('$2'));
         SELECT CONCAT('table ', TABLE_SCHEMA, '.', TABLE_NAME, ' ', PRIVILEGE_TYPE)
           FROM information_schema.TABLE_PRIVILEGES WHERE GRANTEE = @g
         UNION ALL
         SELECT CONCAT('column ', TABLE_SCHEMA, '.', TABLE_NAME, '.', COLUMN_NAME, ' ', PRIVILEGE_TYPE)
           FROM information_schema.COLUMN_PRIVILEGES WHERE GRANTEE = @g
         UNION ALL
         SELECT CONCAT('schema ', TABLE_SCHEMA, ' ', PRIVILEGE_TYPE)
           FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE = @g
         UNION ALL
         SELECT CONCAT('global ', PRIVILEGE_TYPE)
           FROM information_schema.USER_PRIVILEGES WHERE GRANTEE = @g
         UNION ALL
         SELECT CONCAT('routine ', Db, '.', Routine_name, ' ', Proc_priv)
           FROM mysql.procs_priv WHERE User = '$1' AND Host = '$2';" 2>&1 | tr -d '\r' | LC_ALL=C sort
}

EXPECTED=$(LC_ALL=C sort <<'EOF'
column university_resources.users.email INSERT
column university_resources.users.full_name INSERT
column university_resources.users.full_name UPDATE
column university_resources.users.password_hash INSERT
column university_resources.users.password_hash UPDATE
global USAGE
routine campus_audit.import_current_log Execute
schema campus_audit SELECT
table university_resources.audit_events SELECT
table university_resources.audit_lab_notes DELETE
table university_resources.audit_lab_notes INSERT
table university_resources.audit_lab_notes SELECT
table university_resources.audit_lab_notes UPDATE
table university_resources.bookings INSERT
table university_resources.bookings SELECT
table university_resources.bookings UPDATE
table university_resources.items SELECT
table university_resources.loans INSERT
table university_resources.loans SELECT
table university_resources.loans UPDATE
table university_resources.rooms SELECT
table university_resources.users SELECT
EOF
)

expect_privileges() {   # expect_privileges "<description>" <user> <host>
    local got
    got=$(privileges "$2" "$3")
    if [ "$got" = "$EXPECTED" ]; then pass "$1"
    else fail "$1" "differences (< expected, > actual): $(diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$got") | grep '^[<>]' | tr '\n' ';')"; fi
}

sql "DROP USER IF EXISTS '$TEST_USER'@'%';" >/dev/null
if out=$(apply_account_sql 2>&1); then pass "account SQL applies to a fresh account"
else fail "account SQL applies to a fresh account" "$out"; fi
expect_privileges "fresh account: exactly the least-privilege grants" "$TEST_USER" "%"

# An account created by an older version had table-wide INSERT/UPDATE on users.
sql "GRANT INSERT, UPDATE ON university_resources.users TO '$TEST_USER'@'%';" >/dev/null
if out=$(apply_account_sql 2>&1); then pass "account SQL applies to an account with old table-wide users grants"
else fail "account SQL applies to an account with old table-wide users grants" "$out"; fi
expect_privileges "upgraded account: table-wide users INSERT/UPDATE revoked, column grants kept" "$TEST_USER" "%"
if out=$(apply_account_sql 2>&1); then pass "account SQL re-runs without error"
else fail "account SQL re-runs without error" "$out"; fi
expect_privileges "re-run: grants unchanged (column grants are not revoked by the refresh)" "$TEST_USER" "%"

ok() {   # ok "<description>" "<statement>"
    local out
    if out=$(sql_test "$2" 2>&1); then pass "$1"; else fail "$1" "$(printf '%s' "$out" | tr -d '\r')"; fi
}
denied() {   # denied "<description>" <error code> "<statement>"
    local out
    out=$(sql_test "$3" 2>&1 | tr -d '\r')
    if printf '%s' "$out" | grep -q "^ERROR $2 "; then pass "$1"; else fail "$1" "expected ERROR $2, got: ${out:-no error}"; fi
}

U=university_resources
ok "registration: INSERT (full_name, email, password_hash) into users (rolled back)" \
   "START TRANSACTION;
    INSERT INTO $U.users (full_name, email, password_hash)
    VALUES ('Grant Test', 'grant.test.$$@example.edu', 'not-a-login-hash');
    ROLLBACK;"
ok "account settings: UPDATE users.full_name" "UPDATE $U.users SET full_name = full_name WHERE user_id = 0;"
ok "account settings: UPDATE users.password_hash" "UPDATE $U.users SET password_hash = password_hash WHERE user_id = 0;"
denied "UPDATE users.role is refused" 1143 "UPDATE $U.users SET role = 'admin' WHERE user_id = 0;"
denied "UPDATE users.is_active is refused" 1143 "UPDATE $U.users SET is_active = TRUE WHERE user_id = 0;"
denied "UPDATE users.email is refused" 1143 "UPDATE $U.users SET email = email WHERE user_id = 0;"
denied "INSERT users with a role is refused" 1143 \
   "INSERT INTO $U.users (full_name, email, password_hash, role)
    VALUES ('Grant Test', 'grant.role.$$@example.edu', 'not-a-login-hash', 'admin');"
denied "DELETE FROM users is refused" 1142 "DELETE FROM $U.users WHERE user_id = 0;"
denied "INSERT INTO audit_events is refused" 1142 \
   "INSERT INTO $U.audit_events (action, entity_table, entity_id) VALUES ('DELETE', 'x', '1');"
denied "UPDATE audit_events is refused" 1142 "UPDATE $U.audit_events SET entity_id = entity_id WHERE event_id = 0;"
denied "DELETE FROM audit_events is refused" 1142 "DELETE FROM $U.audit_events WHERE event_id = 0;"
denied "INSERT INTO campus_audit.plugin_events is refused" 1142 \
   "INSERT INTO campus_audit.plugin_events (instance_id, seq, event_time, event_type, record)
    VALUES ('x', 1, NOW(6), 'x', '{}');"
denied "DELETE FROM loans is refused" 1142 "DELETE FROM $U.loans WHERE loan_id = 0;"
ok "UPDATE loans SET status = 'cancelled' is allowed" "UPDATE $U.loans SET status = 'cancelled' WHERE loan_id = 0;"
ok "DELETE FROM audit_lab_notes is allowed" "DELETE FROM $U.audit_lab_notes WHERE note_id = 0;"
denied "CALL import_plugin_log() (needs FILE) is refused" 1370 "CALL campus_audit.import_plugin_log('x');"
out=$(sql_test "CALL campus_audit.import_current_log();" 2>&1 | tr -d '\r')
if printf '%s' "$out" | grep -q -E '^ERROR (1370|1142|1044|1227) '; then
    fail "CALL import_current_log() is permitted" "$out"
else
    # Without the plugin the procedure itself signals 45000; that still proves EXECUTE.
    result=$(printf '%s\n' "$out" | grep '^ERROR' | head -n 1 | cut -c1-70)
    pass "CALL import_current_log() is permitted (result: ${result:-imported})"
fi

app_host=${CAMPUS_APP_HOST:-%}
if [ "$(sql "SELECT COUNT(*) FROM mysql.global_priv WHERE User = 'campus_app' AND Host = '$app_host';" 2>/dev/null | tr -d '\r')" = "1" ]; then
    expect_privileges "installed campus_app@$app_host: exactly the least-privilege grants" campus_app "$app_host"
else
    skip "campus_app@$app_host does not exist on this server"
fi

echo "== $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
