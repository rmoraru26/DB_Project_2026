#!/usr/bin/env bash
# Checks migration 006 (loans.status 'cancelled') against a disposable copy of
# the official schema, so the migration really starts from the pre-006
# enum('active','returned','lost') and the live database is never altered:
#
#   1. database/schema.sql is loaded into a scratch database
#      (frantastic_m006_test_<pid>) and given active, future, returned and
#      lost loans;
#   2. migration 006 runs twice; the ENUM gains 'cancelled', the default stays
#      'active', and no loan row is deleted or rewritten;
#   3. a future active loan can be cancelled with returned_at = NULL, and
#      chk_loans_status_returned_consistent still rejects inconsistent rows;
#   4. an unexpected loans.status definition makes the migration fail without
#      altering the column.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/test_cancelled_loan_migration.sh
#
# ADMINISTRATOR ACCESS (creates and drops one scratch database).

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
SCRATCH=frantastic_m006_test_$$
MIGRATION=database/migrations/006_cancelled_loan_status.sql
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }

sql() { printf 'USE %s;\n%s\n' "$SCRATCH" "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }
in_scratch() { sed "s/university_resources/$SCRATCH/g" "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }
item() { printf "(SELECT item_id FROM items WHERE asset_tag = '%s')" "$1"; }   # items also has a status column
check() {    # check "<description>" "<SQL returning 1 when true>"
    local out
    out=$(sql "$2" 2>&1 | tr -d '\r')
    if [ "$out" = "1" ]; then pass "$1"; else fail "$1" "got: $out"; fi
}
expect_error() {   # expect_error "<description>" <error code> <name in message> "<statement>"
    local out
    out=$(sql "$4" 2>&1 | tr -d '\r')
    if printf '%s' "$out" | grep -q "ERROR $2" && printf '%s' "$out" | grep -q -F "$3"; then pass "$1"
    else fail "$1" "expected ERROR $2 naming $3, got: $out"; fi
}

cleanup() {
    printf 'DROP DATABASE IF EXISTS %s;\n' "$SCRATCH" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch >/dev/null 2>&1
}
trap cleanup EXIT

if ! out=$(in_scratch database/schema.sql 2>&1); then
    echo "FAIL: could not load database/schema.sql into $SCRATCH: $out"
    exit 1
fi
check "scratch copy starts from the official enum('active','returned','lost')" \
    "SELECT COLUMN_TYPE = 'enum(''active'',''returned'',''lost'')' FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'loans' AND COLUMN_NAME = 'status';"

sql "INSERT INTO users (full_name, email, password_hash)
     VALUES ('Loan Migration Test', 'm006.test@example.edu', 'not-a-login-hash');
     INSERT INTO items (name, asset_tag)
     VALUES ('M006 kit 1', 'M006-1'), ('M006 kit 2', 'M006-2'), ('M006 kit 3', 'M006-3'), ('M006 kit 4', 'M006-4');
     SET @u = (SELECT user_id FROM users WHERE email = 'm006.test@example.edu');
     INSERT INTO loans (user_id, item_id, borrowed_at, due_at, returned_at, status)
     SELECT @u, item_id, b, d, r, s FROM items JOIN (
         SELECT 'M006-1' AS tag, NOW(6) - INTERVAL 1 DAY AS b, NOW(6) + INTERVAL 6 DAY AS d, NULL AS r, 'active' AS s
         UNION ALL SELECT 'M006-2', NOW(6) + INTERVAL 3 DAY, NOW(6) + INTERVAL 10 DAY, NULL, 'active'
         UNION ALL SELECT 'M006-3', NOW(6) - INTERVAL 9 DAY, NOW(6) - INTERVAL 2 DAY, NOW(6) - INTERVAL 3 DAY, 'returned'
         UNION ALL SELECT 'M006-4', NOW(6) - INTERVAL 30 DAY, NOW(6) - INTERVAL 20 DAY, NULL, 'lost'
     ) AS f ON f.tag = items.asset_tag;" >/dev/null || { echo "FAIL: fixture rows"; exit 1; }

FINGERPRINT="SELECT CONCAT(COUNT(*), ':', MD5(GROUP_CONCAT(CONCAT_WS('|', loan_id, user_id, item_id, borrowed_at,
                    IFNULL(due_at, '-'), IFNULL(returned_at, '-'), status, created_at, updated_at) ORDER BY loan_id)))
               FROM loans"
before=$(sql "$FINGERPRINT;")

for run in 1 2; do
    if out=$(in_scratch "$MIGRATION" 2>&1); then pass "migration 006 run $run succeeds"
    else fail "migration 006 run $run succeeds" "$out"; fi
done
check "loans.status is enum('active','returned','lost','cancelled')" \
    "SELECT COLUMN_TYPE = 'enum(''active'',''returned'',''lost'',''cancelled'')' FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'loans' AND COLUMN_NAME = 'status';"
check "loans.status stays NOT NULL with default 'active'" \
    "SELECT IS_NULLABLE = 'NO' AND COLUMN_DEFAULT IN ('active', '''active''') FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'loans' AND COLUMN_NAME = 'status';"
after=$(sql "$FINGERPRINT;")
if [ -n "$before" ] && [ "$before" = "$after" ] && [ "${before%%:*}" = "4" ]; then
    pass "no loan row was deleted or rewritten (4 rows, identical values and updated_at)"
else
    fail "no loan row was deleted or rewritten" "before $before, after $after"
fi
check "the current active loan is still active" \
    "SELECT status = 'active' AND returned_at IS NULL FROM loans WHERE item_id = $(item M006-1);"
check "an insert without status still gets 'active'" \
    "START TRANSACTION;
     INSERT INTO loans (user_id, item_id, due_at)
     SELECT user_id, (SELECT item_id FROM items WHERE asset_tag = 'M006-1'), NOW(6) + INTERVAL 1 DAY
       FROM users WHERE email = 'm006.test@example.edu';
     SELECT status = 'active' FROM loans WHERE loan_id = LAST_INSERT_ID();
     ROLLBACK;"
check "the chk_loans_status_returned_consistent constraint is still present" \
    "SELECT COUNT(*) = 1 FROM information_schema.CHECK_CONSTRAINTS
      WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'loans'
        AND CONSTRAINT_NAME = 'chk_loans_status_returned_consistent';"

check "a future active loan is cancelled by an UPDATE with returned_at = NULL" \
    "UPDATE loans SET status = 'cancelled'
      WHERE item_id = $(item M006-2) AND status = 'active' AND borrowed_at > CURRENT_TIMESTAMP(6);
     SELECT ROW_COUNT() = 1;"
check "the cancelled loan keeps its row, dates and returned_at = NULL" \
    "SELECT status = 'cancelled' AND returned_at IS NULL AND borrowed_at > NOW(6) AND due_at IS NOT NULL
       FROM loans WHERE item_id = $(item M006-2);"
expect_error "a cancelled loan with returned_at is rejected" 4025 chk_loans_status_returned_consistent \
    "UPDATE loans SET returned_at = NOW(6) + INTERVAL 4 DAY WHERE item_id = $(item M006-2);"
expect_error "a returned loan without returned_at is still rejected" 4025 chk_loans_status_returned_consistent \
    "UPDATE loans SET returned_at = NULL WHERE item_id = $(item M006-3);"
expect_error "an active loan with returned_at is still rejected" 4025 chk_loans_status_returned_consistent \
    "UPDATE loans SET returned_at = NOW(6) WHERE item_id = $(item M006-1);"
check "the returned and lost loans are unchanged" \
    "SELECT SUM(item_id = $(item M006-3) AND status = 'returned' AND returned_at IS NOT NULL)
          + SUM(item_id = $(item M006-4) AND status = 'lost' AND returned_at IS NULL) = 2
       FROM loans;"

settled=$(sql "$FINGERPRINT;")
if out=$(in_scratch "$MIGRATION" 2>&1) && [ "$(sql "$FINGERPRINT;")" = "$settled" ]; then
    pass "re-running migration 006 on a migrated table changes nothing (cancelled row kept)"
else
    fail "re-running migration 006 on a migrated table changes nothing" "$out"
fi

sql "ALTER TABLE loans MODIFY status ENUM('active', 'returned', 'lost', 'cancelled', 'archived') NOT NULL DEFAULT 'active';" >/dev/null
out=$(in_scratch "$MIGRATION" 2>&1); status=$?
if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -q 'migration 006'; then
    pass "an unexpected loans.status definition stops migration 006"
else
    fail "an unexpected loans.status definition stops migration 006" "exit $status: $out"
fi
check "... and leaves that definition unchanged" \
    "SELECT COLUMN_TYPE LIKE '%''archived'')' FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'loans' AND COLUMN_NAME = 'status';"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
