#!/usr/bin/env bash
# Checks the row-history triggers of database/triggers.sql on the installed
# database:
#   1. the six legacy triggers of database/sql/audit_triggers.sql are gone and
#      every audited table has exactly one AFTER trigger per INSERT, UPDATE and
#      DELETE (so no change can be recorded twice);
#   2. the team's database/tests/test_audit_triggers.sql yields exactly one
#      history row per booking/loan INSERT, UPDATE and DELETE, attributed to
#      the session (connection_id, database_user = USER(), direct_sql);
#   3. with @app_user_id set, history rows carry the application user, and a
#      future loan cancelled with status 'cancelled' (migration 006) is
#      recorded as one UPDATE.
# All row changes are made in transactions and rolled back.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/test_audit_triggers.sh
#
# ADMINISTRATOR ACCESS (reads university_resources; changes are rolled back).
# Needs the seed rows (alice.student@example.edu, Project Room 12, DEMO-SCOPE-001).

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }
sql() { printf 'USE university_resources;\n%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }
check() {    # check "<description>" "<SQL returning 1 when true>"
    local out
    out=$(sql "$2" 2>&1 | tr -d '\r')
    if [ "$out" = "1" ]; then pass "$1"; else fail "$1" "got: $out"; fi
}

check "legacy triggers trg_{bookings,loans}_a{i,u,d}_audit are absent" \
    "SELECT COUNT(*) = 0 FROM information_schema.TRIGGERS
      WHERE TRIGGER_SCHEMA = 'university_resources'
        AND TRIGGER_NAME IN ('trg_bookings_ai_audit', 'trg_bookings_au_audit', 'trg_bookings_ad_audit',
                             'trg_loans_ai_audit', 'trg_loans_au_audit', 'trg_loans_ad_audit');"
for table in users rooms items bookings loans audit_lab_notes; do
    for event in INSERT UPDATE DELETE; do
        name="trg_${table}_audit_$(printf '%s' "$event" | tr 'A-Z' 'a-z')"
        check "$table $event: exactly one trigger, $name (AFTER)" \
            "SELECT COUNT(*) = 1 AND MAX(TRIGGER_NAME) = '$name' AND MAX(ACTION_TIMING) = 'AFTER'
               FROM information_schema.TRIGGERS
              WHERE TRIGGER_SCHEMA = 'university_resources'
                AND EVENT_OBJECT_TABLE = '$table' AND EVENT_MANIPULATION = '$event';"
    done
done

# The team's manual test, checked automatically.  Its last result set is one
# "<table> <action> <count>" row per table and action.
out=$("${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names < database/tests/test_audit_triggers.sql 2>&1 | tr -d '\r')
status=0
printf '%s\n' "$out" | grep -q '^ERROR' && status=1
counts=$(printf '%s\n' "$out" | awk -F'\t' 'NF == 3 && ($1 == "bookings" || $1 == "loans") { print $1, $2, $3 }' | LC_ALL=C sort)
expected="bookings DELETE 1
bookings INSERT 1
bookings UPDATE 1
loans DELETE 1
loans INSERT 1
loans UPDATE 1"
if [ "$status" -eq 0 ] && [ "$counts" = "$expected" ]; then
    pass "test_audit_triggers.sql: one history row per booking/loan INSERT, UPDATE, DELETE (no duplicates)"
else
    fail "test_audit_triggers.sql: one history row per booking/loan INSERT, UPDATE, DELETE" \
         "got: $(printf '%s' "$counts" | tr '\n' ';') $(printf '%s\n' "$out" | grep '^ERROR')"
fi
events=$(printf '%s\n' "$out" | awk -F'\t' 'NF == 11 && $4 ~ /^(bookings|loans)$/')
if [ "$(printf '%s\n' "$events" | grep -c .)" -eq 6 ] \
   && ! printf '%s\n' "$events" | awk -F'\t' '$6 == "NULL" || $8 == "NULL" || $11 != "direct_sql" || $7 != "NULL" { bad = 1 } END { exit !bad }'; then
    pass "test_audit_triggers.sql: rows carry database_user, connection_id and event_source=direct_sql"
else
    fail "test_audit_triggers.sql: rows carry database_user, connection_id and event_source=direct_sql" "$events"
fi

check "application attribution and a loan cancellation, one history row each" \
    "START TRANSACTION;
     SET @alice = (SELECT user_id FROM users WHERE email = 'alice.student@example.edu');
     SET @start = (SELECT COALESCE(MAX(event_id), 0) FROM audit_events);
     SET @app_user_id = @alice;
     INSERT INTO bookings (user_id, room_id, start_time, end_time)
     SELECT @alice, room_id, NOW(6) + INTERVAL 20 DAY, NOW(6) + INTERVAL 20 DAY + INTERVAL 1 HOUR
       FROM rooms WHERE name = 'Project Room 12';
     SET @b = LAST_INSERT_ID();
     INSERT INTO loans (user_id, item_id, borrowed_at, due_at)
     SELECT @alice, item_id, NOW(6) + INTERVAL 5 DAY, NOW(6) + INTERVAL 12 DAY
       FROM items WHERE asset_tag = 'DEMO-SCOPE-001';
     SET @l = LAST_INSERT_ID();
     UPDATE loans SET status = 'cancelled'
      WHERE loan_id = @l AND status = 'active' AND borrowed_at > CURRENT_TIMESTAMP(6);
     SET @app_user_id = NULL;
     SELECT
         (SELECT COUNT(*) FROM audit_events WHERE event_id > @start AND connection_id = CONNECTION_ID()) = 3
     AND (SELECT COUNT(*) FROM audit_events
           WHERE event_id > @start AND connection_id = CONNECTION_ID()
             AND entity_table = 'bookings' AND action = 'INSERT' AND entity_id = CAST(@b AS CHAR)
             AND event_source = 'application' AND application_user_id = @alice
             AND database_user = USER()) = 1
     AND (SELECT COUNT(*) FROM audit_events
           WHERE event_id > @start AND connection_id = CONNECTION_ID()
             AND entity_table = 'loans' AND action = 'UPDATE' AND entity_id = CAST(@l AS CHAR)
             AND event_source = 'application' AND application_user_id = @alice
             AND JSON_VALUE(old_values, '$.status') = 'active'
             AND JSON_VALUE(new_values, '$.status') = 'cancelled'
             AND JSON_TYPE(JSON_EXTRACT(new_values, '$.returned_at')) = 'NULL') = 1;
     ROLLBACK;"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
