#!/usr/bin/env bash
# Runs the team's database/database_tests.sql and checks its annotations
# automatically instead of by eye:
#   1. TEST 1-3 print the tables and the rows named as "Expected sample";
#   2. every "-- Expected: ERROR <code>, <constraint>." line is met, in file
#      order, by an error with that code whose message names that constraint;
#   3. no other error occurs, and the file runs to its last statement.
# The SQL file rolls back every change it makes.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/run_database_tests.sh
#
# ADMINISTRATOR ACCESS (reads university_resources; changes are rolled back).

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
FILE=database/database_tests.sql
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }
has_row() { printf '%s\n' "$out" | grep -F "$1" | grep -F "$2" | grep -q -F "$3"; }

# --force: carry on after the expected errors; the client reports them on stderr.
out=$("${CLIENT[@]}" -u"$ADMIN_USER" --batch --force < "$FILE" 2>&1 | tr -d '\r')

missing=""
for t in users rooms items bookings loans audit_events audit_lab_notes; do
    printf '%s\n' "$out" | grep -q -x "$t" || missing="$missing $t"
done
if [ -z "$missing" ]; then pass "TEST 1: all seven tables exist"; else fail "TEST 1: all seven tables exist" "missing:$missing"; fi
has_row "Alice Student" "Room 201" "confirmed" && pass "TEST 2: Alice Student, Room 201, confirmed" \
    || fail "TEST 2: Alice Student, Room 201, confirmed"
has_row "Alice Student" "Arduino Starter Kit" "returned" && pass "TEST 3: Alice Student, Arduino Starter Kit, returned" \
    || fail "TEST 3: Alice Student, Arduino Starter Kit, returned"

errors=$(printf '%s\n' "$out" | grep '^ERROR ')
expected=$(tr -d '\r' < "$FILE" | sed -n 's/^-- Expected: ERROR \([0-9][0-9]*\), \([A-Za-z0-9_]*\)\.$/\1 \2/p')
n=0
while read -r code constraint; do
    [ -n "$code" ] || continue
    n=$((n + 1))
    line=$(printf '%s\n' "$errors" | sed -n "${n}p")
    if printf '%s' "$line" | grep -q "^ERROR $code " && printf '%s' "$line" | grep -q -F "$constraint"; then
        pass "expected error $n: ERROR $code naming $constraint"
    else
        fail "expected error $n: ERROR $code naming $constraint" "got: ${line:-no error}"
    fi
done <<EOF
$expected
EOF
total=$(printf '%s\n' "$errors" | grep -c '^ERROR ')
if [ "$n" -gt 0 ] && [ "$total" -eq "$n" ]; then
    pass "no other error ($total errors, each one expected)"
else
    fail "no other error" "$total errors for $n expected"
fi
printf '%s\n' "$out" | grep -q 'Initial database checks finished' && pass "the file ran to its last statement" \
    || fail "the file ran to its last statement"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
