#!/usr/bin/env bash
# Migration 007 on the server: the demo-student constraint and procedures.
#
#   1. In a scratch database (a copy of the users table's definition, created
#      and dropped by this test) the real migration text is applied: it adds
#      chk_users_demo_is_student, is idempotent, refuses to run over a
#      conflicting privileged row, and its procedures create / keep / rotate
#      exactly one student row and accept nothing but a Werkzeug hash.
#   2. In the installed database nothing is changed: the constraint and both
#      procedures exist, the web application account cannot execute them, and
#      an attempt to give the demo identity the administrator role is refused
#      by the server (ER 4025) even for the administrator connection.
#
# The procedures name the demo e-mail address themselves, so calling them in
# university_resources would rotate the real demo password; that is why part 1
# runs on a copy.  The dummy hashes below are not hashes of any password.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/test_demo_student.sh
#
# ADMINISTRATOR ACCESS (creates and drops one scratch database).

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
SCRATCH=frt_demo_test_$$
EMAIL=demo.student@frantastic.local
HASH_A='pbkdf2:sha256:1$testsalt$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
HASH_B='scrypt:32768:8:1$testsalt$bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }
sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names 2>&1 | tr -d '\r'; }
scratch() { sql "USE $SCRATCH; $1"; }
expect() {      # expect "<description>" "<expected output>" "<statements in the scratch database>"
    local got
    got=$(scratch "$3")
    if [ "$got" = "$2" ]; then pass "$1"; else fail "$1" "expected '$2', got '$got'"; fi
}
expect_error() {   # expect_error "<description>" <error code> "<statements in the scratch database>"
    local got
    got=$(scratch "$3")
    if printf '%s' "$got" | grep -q "^ERROR $2 "; then pass "$1"; else fail "$1" "expected ERROR $2, got: ${got:-no error}"; fi
}
migration() {   # the migration text, redirected to the scratch database
    tr -d '\r' < database/migrations/007_local_demo_student.sql | sed "s/^USE university_resources;/USE $SCRATCH;/"
}
apply_migration() { migration | "${CLIENT[@]}" -u"$ADMIN_USER" --batch 2>&1 | tr -d '\r'; }

cleanup() { sql "DROP DATABASE IF EXISTS $SCRATCH;" >/dev/null 2>&1; }
trap cleanup EXIT

if [ "$(migration | grep -c "^USE $SCRATCH;")" != 1 ]; then
    echo "FAIL: could not redirect migration 007 to the scratch database; not running it" >&2
    exit 1
fi

# ---------------------------------------------------------------- 1. scratch copy
out=$(sql "DROP DATABASE IF EXISTS $SCRATCH; CREATE DATABASE $SCRATCH CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
           CREATE TABLE $SCRATCH.users LIKE university_resources.users;
           ALTER TABLE $SCRATCH.users DROP CONSTRAINT IF EXISTS chk_users_demo_is_student;")
if [ -z "$out" ]; then pass "scratch copy of the users table created"; else fail "scratch copy of the users table created" "$out"; fi
CONSTRAINT="SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = '$SCRATCH' AND TABLE_NAME = 'users' AND CONSTRAINT_NAME = 'chk_users_demo_is_student' AND CONSTRAINT_TYPE = 'CHECK';"
expect "before the migration the scratch table has no demo constraint" "0" "$CONSTRAINT"

# A privileged row with the demo address stops the migration with an explanation.
scratch "INSERT INTO users (full_name, email, password_hash, role) VALUES ('Squatter', '$EMAIL', 'x', 'admin');" >/dev/null
out=$(apply_migration)
if printf '%s' "$out" | grep -q "ERROR 1644" && printf '%s' "$out" | grep -q "has a non-student role"; then
    pass "a conflicting non-student row stops the migration with a clear message (SQLSTATE 45000)"
else fail "a conflicting non-student row stops the migration" "$out"; fi
expect "the conflicting row was not demoted or removed by the migration" "admin" "SELECT role FROM users WHERE email = '$EMAIL';"
expect "and no constraint was added in that case" "0" "$CONSTRAINT"
scratch "DELETE FROM users;" >/dev/null

out=$(apply_migration)
if [ -z "$out" ]; then pass "migration 007 applies"; else fail "migration 007 applies" "$out"; fi
expect "the migration adds chk_users_demo_is_student" "1" "$CONSTRAINT"
out=$(apply_migration; apply_migration)
if [ -z "$out" ]; then pass "migration 007 re-runs without error"; else fail "migration 007 re-runs without error" "$out"; fi
expect "re-running does not duplicate the constraint" "1" "$CONSTRAINT"
expect "the migration itself creates no account" "0" "SELECT COUNT(*) FROM users;"

expect "bootstrap on an empty table reports CREATED" "CREATED" "CALL bootstrap_local_demo_student('$HASH_A');"
expect "the created row is an active student named Demo Student" "Demo Student|student|1|$HASH_A" \
       "SELECT CONCAT_WS('|', full_name, role, is_active, password_hash) FROM users WHERE email = '$EMAIL';"
expect "a second bootstrap reports EXISTS" "EXISTS" "CALL bootstrap_local_demo_student('$HASH_B');"
expect "and leaves the stored hash unchanged (a restart cannot rotate the password)" "$HASH_A|1" \
       "SELECT CONCAT_WS('|', password_hash, (SELECT COUNT(*) FROM users)) FROM users WHERE email = '$EMAIL';"
expect "rotate reports ROTATED" "ROTATED" "CALL rotate_local_demo_student('$HASH_B');"
expect "and replaces only the hash; the row is still the one student" "$HASH_B|student|1" \
       "SELECT CONCAT_WS('|', password_hash, role, (SELECT COUNT(*) FROM users)) FROM users WHERE email = '$EMAIL';"

expect_error "bootstrap refuses a value that is not a Werkzeug hash" 1644 "CALL bootstrap_local_demo_student('plain-text-password');"
expect_error "rotate refuses a value that is not a Werkzeug hash" 1644 "CALL rotate_local_demo_student('plain-text-password');"
expect_error "rotate refuses NULL" 1644 "CALL rotate_local_demo_student(NULL);"
expect "a refused call changed nothing" "$HASH_B" "SELECT password_hash FROM users WHERE email = '$EMAIL';"

# Inside the caller's open transaction both procedures refuse BEFORE their own
# START TRANSACTION (which would commit the caller's work implicitly) and
# without running their ROLLBACK handler (which would discard it).
for proc in bootstrap_local_demo_student rotate_local_demo_student; do
    got=$(printf '%s\n' "USE $SCRATCH; START TRANSACTION;
        INSERT INTO users (full_name, email, password_hash, role) VALUES ('Txn Probe', 'txn.probe@example.edu', 'x', 'student');
        CALL $proc('$HASH_A');
        SELECT CONCAT('open=', @@in_transaction, ' probe=', (SELECT COUNT(*) FROM users WHERE email = 'txn.probe@example.edu'));
        ROLLBACK;" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names --force 2>&1 | tr -d '\r')
    if printf '%s' "$got" | grep -q "^ERROR 1644 .*refused inside an open transaction" && printf '%s' "$got" | grep -q "^open=1 probe=1$"; then
        pass "$proc refuses inside an open transaction; the caller's transaction is still open with its uncommitted row"
    else fail "$proc inside an open transaction" "$got"; fi
    expect "after the caller's ROLLBACK its row is gone (it was not committed by $proc)" "0" \
           "SELECT COUNT(*) FROM users WHERE email = 'txn.probe@example.edu';"
done
expect "the refusals inside a transaction changed nothing" "$HASH_B" "SELECT password_hash FROM users WHERE email = '$EMAIL';"

expect_error "UPDATE to the administrator role is refused by the CHECK constraint" 4025 \
             "UPDATE users SET role = 'admin' WHERE email = '$EMAIL';"
expect_error "the constraint also covers a differently cased address (the collation is case-insensitive)" 4025 \
             "DELETE FROM users; INSERT INTO users (full_name, email, password_hash, role) VALUES ('X', 'Demo.Student@FRANTASTIC.local', 'x', 'admin');"
expect "documented limit: with check_constraint_checks = 0 a session can bypass the constraint (defence in depth, not a barrier against root)" "admin" \
       "DELETE FROM users; INSERT INTO users (full_name, email, password_hash, role) VALUES ('Demo Student', '$EMAIL', 'x', 'student');
        SET SESSION check_constraint_checks = 0; UPDATE users SET role = 'admin' WHERE email = '$EMAIL'; SELECT role FROM users WHERE email = '$EMAIL';"
scratch "DELETE FROM users WHERE email = '$EMAIL';" >/dev/null
expect "other accounts may still be administrators" "admin" \
       "INSERT INTO users (full_name, email, password_hash, role) VALUES ('Other', 'other.admin@example.edu', 'x', 'admin'); SELECT role FROM users WHERE email = 'other.admin@example.edu';"
# Two result rows (the procedure's answer, then the row count), joined with '|'.
got=$(scratch "DELETE FROM users WHERE email = '$EMAIL'; CALL rotate_local_demo_student('$HASH_A'); SELECT COUNT(*) FROM users;" | tr '\n' '|')
if [ "$got" = "MISSING|1|" ]; then pass "rotate without the demo row: MISSING, no row created, other rows kept"
else fail "rotate without the demo row" "got '$got'"; fi

# ---------------------------------------------------------------- 2. installed database (read-only)
U=university_resources
got=$(sql "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = '$U' AND TABLE_NAME = 'users' AND CONSTRAINT_NAME = 'chk_users_demo_is_student' AND CONSTRAINT_TYPE = 'CHECK';")
if [ "$got" = 1 ]; then pass "installed database: chk_users_demo_is_student exists"; else fail "installed database: chk_users_demo_is_student exists" "$got"; fi
got=$(sql "SELECT GROUP_CONCAT(CONCAT(ROUTINE_NAME, ':', SECURITY_TYPE) ORDER BY ROUTINE_NAME) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$U' AND ROUTINE_NAME IN ('bootstrap_local_demo_student', 'rotate_local_demo_student');")
if [ "$got" = "bootstrap_local_demo_student:DEFINER,rotate_local_demo_student:DEFINER" ]; then pass "installed database: both procedures exist (SQL SECURITY DEFINER)"
else fail "installed database: both procedures exist" "$got"; fi
got=$(sql "SELECT COUNT(*) FROM mysql.procs_priv WHERE Db = '$U' AND Routine_name IN ('bootstrap_local_demo_student', 'rotate_local_demo_student', 'bootstrap_local_admin', 'rotate_local_admin');")
if [ "$got" = 0 ]; then pass "installed database: no account was granted EXECUTE on the credential procedures"
else fail "installed database: no account was granted EXECUTE on the credential procedures" "$got grant(s)"; fi

before=$(sql "SELECT COALESCE(MD5(GROUP_CONCAT(CONCAT_WS('|', user_id, email, password_hash, role, is_active, updated_at) ORDER BY user_id)), 'none') FROM $U.users WHERE email = '$EMAIL';")
got=$(sql "SELECT COUNT(*) FROM $U.users WHERE email = '$EMAIL';")
if [ "$got" = 1 ]; then
    got=$(sql "SELECT CONCAT(role, '|', password_hash REGEXP '^(scrypt|pbkdf2):') FROM $U.users WHERE email = '$EMAIL';")
    if [ "$got" = "student|1" ]; then pass "installed database: the demo account is a student with a Werkzeug hash"
    else fail "installed database: the demo account is a student with a Werkzeug hash" "$got"; fi
    out=$(sql "UPDATE $U.users SET role = 'admin' WHERE email = '$EMAIL';")
else
    echo "NOTE: the installed database has no demo account yet (make up creates it); testing the constraint with an INSERT"
    out=$(sql "INSERT INTO $U.users (full_name, email, password_hash, role) VALUES ('Refused', '$EMAIL', 'x', 'admin');")
fi
if printf '%s' "$out" | grep -q "^ERROR 4025 "; then pass "installed database: the administrator connection cannot give the demo identity the admin role (ER 4025)"
else fail "installed database: promotion of the demo identity is refused" "${out:-no error}"; fi
after=$(sql "SELECT COALESCE(MD5(GROUP_CONCAT(CONCAT_WS('|', user_id, email, password_hash, role, is_active, updated_at) ORDER BY user_id)), 'none') FROM $U.users WHERE email = '$EMAIL';")
if [ -n "$before" ] && [ "$before" = "$after" ]; then pass "installed database: the demo account row is exactly as before this test"
else fail "installed database: the demo account row is exactly as before this test"; fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
