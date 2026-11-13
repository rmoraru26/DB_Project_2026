#!/usr/bin/env bash
# End-to-end tests for the campus_audit plugin against a running MariaDB server.
#
# Everything goes through the SQL client, so the same script runs against the
# Docker setup and against a native Windows server (from Git Bash).  The log
# file is read back with LOAD_FILE(), i.e. by the server itself.
#
# Requirements:
#   * an account with SUPER/ALL privileges and FILE (installs the plugin,
#     changes global variables, creates test users) -- ADMINISTRATOR ACCESS;
#   * the plugin library in the server's plugin_dir;
#   * the server started with plugin_maturity=beta (or lower).
#
# Environment:
#   MARIADB_CLIENT   client command without -u/-p   (default: mariadb)
#   DB_ADMIN_USER    admin account                    (default: root)
#   MYSQL_PWD        admin password, read by the client itself (optional)
#   AUDIT_TEST_DIR   server-side directory for test logs, with trailing
#                    separator; must be readable by LOAD_FILE (secure_file_priv).
#                    Default: the server's datadir.
#   AUDIT_TEST_DENIED_PATH  server-side path the server may not create
#                    (default on Linux: /root/campus_audit_denied.jsonl)
#   CONCURRENT_CLIENTS / CONCURRENT_STATEMENTS  (default 8 / 50)
#   CHANGE_USER_CLIENT  command that runs the campus_change_user helper
#                    (tests/plugin/change_user.c); without it the CHANGE_USER
#                    checks are skipped.  Docker: built into the server image.
#                    Native: compile it, set CU_HOST/CU_PORT for TCP.
#
# Exit status: 0 if every executed check passed.  Skipped checks are listed.

set -u

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
CLIENTS=${CONCURRENT_CLIENTS:-8}
PER_CLIENT=${CONCURRENT_STATEMENTS:-50}
RUN_ID="$(date +%s)_$$"
TEST_PW="t_${RUN_ID}_Pw"          # throwaway password for throwaway test accounts

PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------- helpers

# Statements go through stdin, never the command line: Windows limits a
# command line to 32 kB and Linux a single argument to 128 kB.
sql() {      # sql "<statements>" -> stdout (tab separated, no headers)
    printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names --default-character-set=utf8mb4
}

sql_force() {  # like sql, but continue after errors (to read SHOW WARNINGS)
    printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names --force
}

sql_as() {   # sql_as <user> <password> "<statements>"; the password travels in the environment
    printf '%s\n' "$3" | MYSQL_PWD="$2" "${CLIENT[@]}" -u"$1" --batch --skip-column-names
}

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

check() {    # check "<description>" "<SQL returning 1 when true>"
    local out
    out=$(sql "$2" 2>&1)
    if [ "$out" = "1" ]; then pass "$1"; else fail "$1" "got: $out"; fi
}

expect_error() {   # expect_error "<description>" <error code> "<statement>"
    local out
    out=$(sql "$3" 2>&1)
    if printf '%s' "$out" | grep -q "ERROR $2"; then pass "$1"; else fail "$1" "expected ERROR $2, got: $out"; fi
}

# Reload the current test log into campus_audit_test.log_lines.
reload_log() { sql "CALL campus_audit_test.load_log($LOG_EXPR);" >/dev/null; }

# Count JSON lines in the test log matching an SQL condition on `line`.
count_where() { reload_log; sql "SELECT COUNT(*) FROM campus_audit_test.log_lines WHERE $1;"; }

ev() { echo "JSON_VALUE(line,'\$.$1')"; }

cleanup() {
    sql "SET GLOBAL campus_audit_databases = '${ORIG_DATABASES:-university_resources}';
         SET GLOBAL campus_audit_exclude_users = '${ORIG_EXCLUDE:-}';
         SET GLOBAL campus_audit_log_reads = ${ORIG_LOG_READS:-OFF};
         SET GLOBAL campus_audit_connections = '${ORIG_CONNECTIONS:-FAILED}';
         SET GLOBAL campus_audit_max_sql_length = ${ORIG_MAX_SQL:-1024};" >/dev/null 2>&1
    if [ -n "${ORIG_PATH:-}" ]; then
        sql "SET GLOBAL campus_audit_file_path = '${ORIG_PATH//\\/\\\\}';" >/dev/null 2>&1
    fi
    sql "DROP DATABASE IF EXISTS audit_test_watched;
         DROP DATABASE IF EXISTS audit_test_other;
         DROP DATABASE IF EXISTS campus_audit_test;
         DROP USER IF EXISTS 'ca_test_excluded'@'%', 'ca_test_user'@'%', 'ca_test_cu'@'%', 'ca_test_ro'@'%';" >/dev/null 2>&1
}

# ---------------------------------------------------------------- setup

echo "== campus_audit integration tests (run $RUN_ID)"
if ! VERSION=$(sql "SELECT VERSION();" 2>&1); then
    echo "Cannot connect to the server: $VERSION"
    exit 2
fi
OS=$(sql "SELECT @@version_compile_os;")
echo "Server: $VERSION ($OS)"

# T1: installation
if [ "$(sql "SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';")" = "0" ]; then
    out=$(sql "INSTALL SONAME 'campus_audit';" 2>&1) || { echo "INSTALL failed: $out"; exit 2; }
fi
check "plugin is installed and ACTIVE (information_schema.PLUGINS)" \
    "SELECT PLUGIN_STATUS='ACTIVE' AND PLUGIN_TYPE='AUDIT' FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';"
check "SHOW PLUGINS lists campus_audit" \
    "SELECT COUNT(*) FROM information_schema.ALL_PLUGINS WHERE PLUGIN_NAME='campus_audit' AND PLUGIN_STATUS='ACTIVE';"

ORIG_PATH=$(sql "SELECT @@GLOBAL.campus_audit_file_path;")
ORIG_DATABASES=$(sql "SELECT @@GLOBAL.campus_audit_databases;")
ORIG_EXCLUDE=$(sql "SELECT @@GLOBAL.campus_audit_exclude_users;")
ORIG_LOG_READS=$(sql "SELECT IF(@@GLOBAL.campus_audit_log_reads,'ON','OFF');")
ORIG_CONNECTIONS=$(sql "SELECT @@GLOBAL.campus_audit_connections;")
ORIG_MAX_SQL=$(sql "SELECT @@GLOBAL.campus_audit_max_sql_length;")
trap cleanup EXIT

if [ -n "${AUDIT_TEST_DIR:-}" ]; then
    DIR_EXPR="'${AUDIT_TEST_DIR//\\/\\\\}'"
else
    DIR_EXPR="@@GLOBAL.datadir"
fi
LOG_EXPR="CONCAT($DIR_EXPR, 'campus_audit_test_$RUN_ID.jsonl')"
LOG2_EXPR="CONCAT($DIR_EXPR, 'campus_audit_test_${RUN_ID}_b.jsonl')"

sql "CREATE DATABASE IF NOT EXISTS campus_audit_test;
     CREATE OR REPLACE TABLE campus_audit_test.log_lines (start_pos BIGINT PRIMARY KEY, line LONGTEXT NOT NULL);
     DELIMITER //
     CREATE OR REPLACE PROCEDURE campus_audit_test.load_log(IN p VARCHAR(1024))
     BEGIN
       DECLARE c LONGBLOB;
       SET c = LOAD_FILE(p);
       SET SESSION max_recursive_iterations = 100000000;
       DELETE FROM campus_audit_test.log_lines;
       INSERT INTO campus_audit_test.log_lines (start_pos, line)
       WITH RECURSIVE b (s, e) AS (
         SELECT 1, LOCATE(0x0A, c, 1)
         UNION ALL SELECT e + 1, LOCATE(0x0A, c, e + 1) FROM b WHERE e > 0)
       SELECT s, CONVERT(SUBSTRING(c, s, e - s) USING utf8mb4) FROM b WHERE e > s;
     END //
     DELIMITER ;
     CREATE DATABASE audit_test_watched;
     CREATE DATABASE audit_test_other;
     CREATE TABLE audit_test_other.t (id INT PRIMARY KEY, v VARCHAR(100));
     CREATE USER 'ca_test_excluded'@'%' IDENTIFIED BY '$TEST_PW';
     CREATE USER 'ca_test_user'@'%' IDENTIFIED BY '$TEST_PW';
     GRANT ALL ON audit_test_watched.* TO 'ca_test_excluded'@'%', 'ca_test_user'@'%';" || { echo "setup failed"; exit 2; }

# ---------------------------------------------------------------- configuration validation

echo "-- configuration validation"
expect_error "empty file path rejected" 1231 "SET GLOBAL campus_audit_file_path = '';"
expect_error "NULL file path rejected" 1231 "SET GLOBAL campus_audit_file_path = NULL;"
expect_error "file path in a missing directory rejected" 1231 \
    "SET GLOBAL campus_audit_file_path = CONCAT($DIR_EXPR, 'no_such_dir_$RUN_ID/x.jsonl');"
expect_error "directory-like file path rejected" 1231 "SET GLOBAL campus_audit_file_path = 'some_dir/';"
warn=$(sql_force "SET GLOBAL campus_audit_file_path = CONCAT($DIR_EXPR, 'no_such_dir_$RUN_ID/x.jsonl'); SHOW WARNINGS;" 2>/dev/null)
if printf '%s' "$warn" | grep -q "campus_audit: Cannot open audit log"; then
    pass "rejected path explains the reason in SHOW WARNINGS"
else
    fail "rejected path explains the reason in SHOW WARNINGS" "got: $warn"
fi
check "rejected paths leave the active file unchanged" \
    "SELECT @@GLOBAL.campus_audit_file_path = '${ORIG_PATH//\\/\\\\}';"
expect_error "database list with a space rejected" 1231 "SET GLOBAL campus_audit_databases = 'bad name';"
expect_error "database list with an empty element rejected" 1231 "SET GLOBAL campus_audit_databases = 'a,,b';"
expect_error "database list mixing '*' and names rejected" 1231 "SET GLOBAL campus_audit_databases = '*,a';"
expect_error "user list with punctuation rejected" 1231 "SET GLOBAL campus_audit_exclude_users = 'x;DROP';"
expect_error "unknown connections mode rejected" 1231 "SET GLOBAL campus_audit_connections = 'SOMETIMES';"
expect_error "non-boolean log_reads rejected" 1231 "SET GLOBAL campus_audit_log_reads = 'maybe';"

# The first accepted SET GLOBAL of this run, and the first statement of its
# connection.  The server runs the plugin's update callback with
# LOCK_global_system_variables held; plugin 1.1.0 touched a THDVAR there,
# whose first use in a session takes that lock again, and on Linux the whole
# server hung (the first Docker CI run stopped here).  The time limit turns
# a hang into a failure; the later checks could not run, so the run stops.
if command -v timeout >/dev/null 2>&1; then
    printf 'SET GLOBAL campus_audit_max_sql_length = 999999;\n' |
        timeout 60 "${CLIENT[@]}" -u"$ADMIN_USER" --batch >/dev/null 2>&1
    rc=$?
else
    sql "SET GLOBAL campus_audit_max_sql_length = 999999;" >/dev/null 2>&1
    rc=$?
fi
if [ "$rc" -eq 124 ]; then
    fail "SET GLOBAL as the first statement of a connection returns" "no answer within 60 s"
    echo "== stopping: the server does not answer (deadlock in the update callback?)"
    trap - EXIT
    exit 1
fi
pass "SET GLOBAL as the first statement of a connection returns"
check "out-of-range max_sql_length is clamped to 8192" "SELECT @@GLOBAL.campus_audit_max_sql_length = 8192;"

if [ "${AUDIT_TEST_DENIED_PATH:-}" != "" ] || [ "$OS" != "Win64" ]; then
    DENIED=${AUDIT_TEST_DENIED_PATH:-/root/campus_audit_denied.jsonl}
    expect_error "path without write permission rejected ($DENIED)" 1231 \
        "SET GLOBAL campus_audit_file_path = '${DENIED//\\/\\\\}';"
else
    skip "permission-denied path (set AUDIT_TEST_DENIED_PATH on Windows)"
fi

# ---------------------------------------------------------------- switch to a fresh test log

sql "SET GLOBAL campus_audit_databases = 'audit_test_watched';
     SET GLOBAL campus_audit_exclude_users = 'ca_test_excluded';
     SET GLOBAL campus_audit_log_reads = OFF;
     SET GLOBAL campus_audit_connections = 'FAILED';
     SET GLOBAL campus_audit_max_sql_length = 1024;
     SET GLOBAL campus_audit_file_path = $LOG_EXPR;" || { echo "cannot switch to the test log"; exit 2; }
check "test log is active" "SELECT VARIABLE_VALUE = $LOG_EXPR FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_FILE';"
check "state is ACTIVE" "SELECT VARIABLE_VALUE='ACTIVE' FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_STATE';"

# Every later check reads the log back with LOAD_FILE(), which returns NULL
# for a file that is not readable by all; on Linux the plugin then needs
# campus_audit_readable_by_all = ON (the first Linux CI run failed 42 checks
# with "got: 0" for this reason alone).
if [ "$(sql "SELECT LOAD_FILE($LOG_EXPR) IS NOT NULL;" 2>&1)" = "1" ]; then
    pass "the server can read the test log with LOAD_FILE()"
else
    fail "the server can read the test log with LOAD_FILE()" \
         "LOAD_FILE() reads only files readable by all: set campus_audit_readable_by_all = ON"
    echo "== stopping: every later check reads the log with LOAD_FILE()"
    exit 1
fi

# ---------------------------------------------------------------- event capture

echo "-- event capture"
CONN=$(sql "USE audit_test_watched;
    CREATE TABLE rooms (id INT PRIMARY KEY, name VARCHAR(200), capacity INT CHECK (capacity > 0));
    INSERT INTO rooms VALUES (1, 'Lab \"A\" -- pw=hunter2', 12);
    UPDATE rooms SET capacity = 13 WHERE id = 1;
    SELECT name FROM rooms;
    DELETE FROM rooms WHERE id = 99;
    ALTER TABLE rooms ADD COLUMN note TEXT;
    RENAME TABLE rooms TO rooms_renamed;
    INSERT INTO audit_test_other.t VALUES (1, 'not watched');
    SELECT CONNECTION_ID();" | tail -1)

check "every line is valid JSON" "SELECT $(count_where 1) > 0 AND $(count_where "NOT JSON_VALID(line)") = 0;"
check "CREATE TABLE recorded as table_create" \
    "SELECT $(count_where "$(ev event)='table_create' AND $(ev table)='rooms' AND $(ev db)='audit_test_watched'") = 1;"
check "INSERT/UPDATE/DELETE recorded as table_write (3)" \
    "SELECT $(count_where "$(ev event)='table_write' AND $(ev table)='rooms'") = 3;"
check "ALTER TABLE recorded as table_alter" "SELECT $(count_where "$(ev event)='table_alter' AND $(ev table)='rooms'") = 1;"
check "RENAME TABLE recorded with new_db/new_table" \
    "SELECT $(count_where "$(ev event)='table_rename' AND $(ev table)='rooms' AND $(ev new_table)='rooms_renamed' AND $(ev new_db)='audit_test_watched'") = 1;"
check "SELECT is not recorded while log_reads=OFF" "SELECT $(count_where "$(ev event)='table_read'") = 0;"
check "writes to an unwatched schema are not recorded" "SELECT $(count_where "$(ev db)='audit_test_other'") = 0;"
check "each audited statement has exactly one statement record" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev conn)=$CONN") = 6;"
check "conn equals CONNECTION_ID() of the session" \
    "SELECT $(count_where "$(ev event)='table_write' AND $(ev conn)=$CONN") = 3;"
check "table and statement records share query_id" \
    "SELECT COUNT(*) = 3 FROM campus_audit_test.log_lines w JOIN campus_audit_test.log_lines s
       ON JSON_VALUE(s.line,'\$.query_id') = JSON_VALUE(w.line,'\$.query_id')
      AND JSON_VALUE(s.line,'\$.event')='statement'
     WHERE JSON_VALUE(w.line,'\$.event')='table_write';"
check "statement record carries account, db and status" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev account) LIKE '$ADMIN_USER[%' AND $(ev db)='audit_test_watched' AND $(ev status)='ok' AND $(ev error_code)='0'") = 6;"
check "digest masks literals (no 'hunter2', no 'Lab')" \
    "SELECT $(count_where "line LIKE '%hunter2%' OR line LIKE '%Lab %'") = 0;"
check "digest keeps statement structure" \
    "SELECT $(count_where "$(ev sql_digest)='INSERT INTO rooms VALUES (?, ?, ?)'") = 1;"
check "required fields present on table records" \
    "SELECT $(count_where "$(ev event)='table_write' AND $(ev ts) IS NOT NULL AND $(ev seq) IS NOT NULL AND $(ev instance) IS NOT NULL AND $(ev query_id) IS NOT NULL AND $(ev user)='$ADMIN_USER'") = 3;"
check "ts is ISO-8601 UTC with microseconds" \
    "SELECT $(count_where "$(ev ts) NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\\\.[0-9]{6}Z\$'") = 0;"

# failed statements
sql "USE audit_test_watched; INSERT INTO rooms_renamed (id, name, capacity) VALUES (2, 'x', 0);" >/dev/null 2>&1
sql "USE audit_test_watched; INSERT INTO rooms_renamed (id, name, capacity) VALUES (1, 'dup', 5);" >/dev/null 2>&1
check "failed CHECK constraint recorded with error_code 4025" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev status)='error' AND $(ev error_code)='4025'") = 1;"
check "duplicate key recorded with error_code 1062" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev status)='error' AND $(ev error_code)='1062'") = 1;"

# transactions: the plugin sees statements, not commits
sql "USE audit_test_watched; START TRANSACTION; UPDATE rooms_renamed SET capacity = 99 WHERE id = 1; ROLLBACK;"
check "rolled-back UPDATE still produces table_write + ok statement (not transactional)" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev sql_digest)='UPDATE rooms_renamed SET capacity = ? WHERE id = ?' AND $(ev status)='ok'") = 1;"
check "the rolled-back value is not in the table" "SELECT capacity = 13 FROM audit_test_watched.rooms_renamed WHERE id = 1;"

# ---------------------------------------------------------------- special input

echo "-- special and malformed input"
sql "USE audit_test_watched;
     CREATE TABLE \`q\"uo\\\\te ä\` (id INT);
     INSERT INTO \`q\"uo\\\\te ä\` VALUES (1);" >/dev/null 2>&1
check "table name with quote, backslash and UTF-8 is escaped correctly" \
    "SELECT $(count_where "JSON_VALID(line) AND $(ev event)='table_write' AND $(ev table)=CONVERT(_utf8mb4'q\"uo\\\\\\\\te ä' USING utf8mb4)") = 1;"
LONG=$(head -c 200000 < /dev/zero | tr '\0' 'x')
sql "USE audit_test_watched; INSERT INTO rooms_renamed (id, name, capacity) VALUES (3, '${LONG:0:200}', 1);
     CREATE TABLE big (v LONGTEXT); INSERT INTO big VALUES ('$LONG');" >/dev/null
check "200 kB literal produces a short digest" \
    "SELECT $(count_where "$(ev sql_digest)='INSERT INTO big VALUES (?)' AND LENGTH(line) < 1000") = 1;"
COLS=$(for i in $(seq 1 200); do printf 'c%03d INT, ' "$i"; done)
sql "USE audit_test_watched; CREATE TABLE wide (${COLS} id INT);" >/dev/null
check "over-long statement digest is truncated at max_sql_length and flagged" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev sql_digest_truncated)=1 AND LENGTH($(ev sql_digest)) <= 1024") >= 1;"
sql "USE audit_test_watched; INSERT INTO rooms_renamed (id, name, capacity) VALUES (4, CONCAT('nl', CHAR(10), 'tab', CHAR(9), _utf8mb4'😀'), 1);
     INSERT INTO rooms_renamed (id, name, capacity) VALUES (5, '', 1);" >/dev/null
check "newline, tab, emoji and empty literals never break a line" \
    "SELECT $(count_where "NOT JSON_VALID(line)") = 0;"
# Under NO_BACKSLASH_ESCAPES 'C:\' is a complete literal; read with the default
# rules it runs on, and the next literal would reach the digest.  The client
# follows the server's NO_BACKSLASH_ESCAPES status when it splits statements.
sql "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES'); USE audit_test_watched;
     INSERT INTO rooms_renamed (id, name, capacity) VALUES (60, 'C:\\', 1), (61, 'nbe_secret_$RUN_ID', 1);" >/dev/null
check "NO_BACKSLASH_ESCAPES: 'C:\\' does not let the next literal into the log" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev sql_digest)='INSERT INTO rooms_renamed (id, name, capacity) VALUES (?, ?'") = 1
            AND $(count_where "line LIKE '%nbe_secret%'") = 0
            AND (SELECT COUNT(*) FROM audit_test_watched.rooms_renamed WHERE id IN (60, 61)) = 2;"
sql "SET GLOBAL campus_audit_max_sql_length = 0; USE audit_test_watched; UPDATE rooms_renamed SET capacity = 2 WHERE id = 5; SET GLOBAL campus_audit_max_sql_length = 1024;" >/dev/null
check "max_sql_length=0 omits the digest" \
    "SELECT $(count_where "$(ev event)='statement' AND line NOT LIKE '%sql_digest%' AND $(ev conn) IS NOT NULL") >= 1;"

# ---------------------------------------------------------------- filtering

echo "-- filtering"
sql "SET GLOBAL campus_audit_log_reads = ON; SELECT COUNT(*) FROM audit_test_watched.rooms_renamed;" >/dev/null
check "log_reads=ON records SELECT as table_read" \
    "SELECT $(count_where "$(ev event)='table_read' AND $(ev table)='rooms_renamed'") = 1;"
sql "SET GLOBAL campus_audit_log_reads = OFF;"
before=$(sql "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_EVENTS_FILTERED';")
sql_as ca_test_excluded "$TEST_PW" "INSERT INTO audit_test_watched.rooms_renamed (id, name, capacity) VALUES (10, 'excluded', 1);"
sql_as ca_test_user "$TEST_PW" "INSERT INTO audit_test_watched.rooms_renamed (id, name, capacity) VALUES (11, 'included', 1);"
check "excluded user's write is not recorded" "SELECT $(count_where "$(ev user)='ca_test_excluded' OR $(ev account) LIKE 'ca_test_excluded%'") = 0;"
check "non-excluded user's write is recorded" "SELECT $(count_where "$(ev event)='table_write' AND $(ev user)='ca_test_user'") = 1;"
check "events_filtered counter increased" \
    "SELECT VARIABLE_VALUE > $before FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_EVENTS_FILTERED';"
sql "SET GLOBAL campus_audit_databases = '*'; INSERT INTO audit_test_other.t VALUES (2, 'now watched'); SELECT COUNT(*) FROM mysql.user;" >/dev/null
check "databases='*' records other user schemas" "SELECT $(count_where "$(ev db)='audit_test_other' AND $(ev event)='table_write'") = 1;"
check "databases='*' never records the mysql schema" "SELECT $(count_where "$(ev db)='mysql'") = 0;"
sql "SET GLOBAL campus_audit_databases = 'audit_test_watched';"

# Statements the privilege system refuses.  The privilege check runs before
# the server opens a table, so they raise no TABLE event; since 1.1.0 the
# plugin records them from GENERAL STATUS when the default schema is watched.
echo "-- refused statements (privilege errors)"
sql "CREATE USER 'ca_test_ro'@'%' IDENTIFIED BY '$TEST_PW';
     GRANT SELECT ON audit_test_watched.* TO 'ca_test_ro'@'%';
     GRANT SELECT ON audit_test_other.* TO 'ca_test_ro'@'%';"
RO_CONN=$(sql_as ca_test_ro "$TEST_PW" "SELECT CONNECTION_ID(); USE audit_test_watched; DELETE FROM rooms_renamed WHERE id = -1;" 2>/dev/null | head -1)
RO_CONN=${RO_CONN:-0}
check "refused DELETE (ER 1142) in a watched default schema is recorded with access_denied" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev conn)=$RO_CONN AND $(ev error_code)='1142' AND $(ev access_denied)=1 AND $(ev db)='audit_test_watched' AND $(ev sql_digest)='DELETE FROM rooms_renamed WHERE id = -?'") = 1;"
check "the refused statement raised no TABLE event" \
    "SELECT $(count_where "$(ev conn)=$RO_CONN AND $(ev event) LIKE 'table\\_%'") = 0;"
RO_CONN2=$(sql_as ca_test_ro "$TEST_PW" "SELECT CONNECTION_ID(); USE audit_test_other; DELETE FROM t WHERE id = -1;" 2>/dev/null | head -1)
check "refused statement in an unwatched default schema is not recorded" \
    "SELECT $(count_where "$(ev conn)=${RO_CONN2:-0}") = 0;"
RO_CONN3=$(sql_as ca_test_ro "$TEST_PW" "SELECT CONNECTION_ID(); USE audit_test_other; DELETE FROM audit_test_watched.rooms_renamed WHERE id = -1;" 2>/dev/null | head -1)
check "known limit: a refused statement naming a watched table from another default schema is not recorded" \
    "SELECT $(count_where "$(ev conn)=${RO_CONN3:-0}") = 0;"
RO_CONN4=$(sql_as ca_test_ro "$TEST_PW" "SELECT CONNECTION_ID(); USE audit_test_watched; SET GLOBAL campus_audit_databases = '*';" 2>/dev/null | head -1)
check "attempted SET GLOBAL campus_audit_* without the privilege is recorded (ER 1227)" \
    "SELECT $(count_where "$(ev conn)=${RO_CONN4:-0} AND $(ev error_code)='1227' AND $(ev access_denied)=1") = 1;"
check "the refused SET GLOBAL changed nothing" "SELECT @@GLOBAL.campus_audit_databases = 'audit_test_watched';"
before=$(sql "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_EVENTS_FILTERED';")
EX_CONN=$(sql_as ca_test_excluded "$TEST_PW" "SELECT CONNECTION_ID(); USE audit_test_watched; SET GLOBAL campus_audit_log_reads = ON;" 2>/dev/null | head -1)
check "an excluded user's refused statement is not recorded, but counted as filtered" \
    "SELECT $(count_where "$(ev conn)=${EX_CONN:-0}") = 0 AND (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_EVENTS_FILTERED') > $before;"

# connections
sql_as ca_test_user wrong_password "SELECT 1;" >/dev/null 2>&1
check "connections=FAILED records a failed login (status 1045)" \
    "SELECT $(count_where "$(ev event)='connect_failed' AND $(ev user)='ca_test_user' AND $(ev status)='1045'") = 1;"
check "connections=FAILED does not record successful logins" "SELECT $(count_where "$(ev event) IN ('connect','disconnect')") = 0;"
sql "SET GLOBAL campus_audit_connections = 'ALL';"
sql_as ca_test_user "$TEST_PW" "SELECT 1;" >/dev/null
check "connections=ALL records connect and disconnect" \
    "SELECT $(count_where "$(ev event)='connect' AND $(ev user)='ca_test_user'") = 1 AND $(count_where "$(ev event)='disconnect' AND $(ev user)='ca_test_user'") = 1;"
check "no password text appears anywhere in the log" "SELECT $(count_where "line LIKE '%wrong_password%' OR line LIKE '%$TEST_PW%'") = 0;"
sql "SET GLOBAL campus_audit_connections = 'NONE';"
sql_as ca_test_user wrong_password "SELECT 1;" >/dev/null 2>&1
check "connections=NONE records nothing" "SELECT $(count_where "$(ev event)='connect_failed'") = 1;"
sql "SET GLOBAL campus_audit_connections = 'FAILED';"

# CHANGE_USER: the mariadb client cannot send COM_CHANGE_USER, so a small C
# program (tests/plugin/change_user.c) calls mysql_change_user(): first to
# ca_test_cu with the right password, then back to ca_test_user with a wrong one.
echo "-- CHANGE_USER (COM_CHANGE_USER through the C API)"
run_change_user() {   # run_change_user -> helper output; passwords travel in the environment
    if command -v timeout >/dev/null 2>&1; then
        CU_PW1="$TEST_PW" CU_PW2="$TEST_PW" timeout 60 $CHANGE_USER_CLIENT ca_test_user ca_test_cu 2>&1
    else
        CU_PW1="$TEST_PW" CU_PW2="$TEST_PW" $CHANGE_USER_CLIENT ca_test_user ca_test_cu 2>&1
    fi
}
if [ -n "${CHANGE_USER_CLIENT:-}" ]; then
    sql "CREATE USER 'ca_test_cu'@'%' IDENTIFIED BY '$TEST_PW';"
    sql "SET GLOBAL campus_audit_connections = 'ALL';"
    out=$(run_change_user)
    sleep 2   # the server writes the disconnect record after the client has gone (observed: ~1 s)
    CU_CONN=$(printf '%s\n' "$out" | awk '$1 == "CONN" {print $2}' | tr -d '\r')
    if printf '%s' "$out" | grep -q '^CHANGE_OK ca_test_cu@' && printf '%s' "$out" | grep -q '^CHANGE_FAILED 1045'; then
        pass "mysql_change_user(): switch to ca_test_cu works, wrong password refused with 1045"
    else
        fail "mysql_change_user(): switch to ca_test_cu works, wrong password refused with 1045" "got: $out"
    fi
    CU_CONN=${CU_CONN:-0}
    check "connections=ALL records the successful switch as change_user, status 0" \
        "SELECT $(count_where "$(ev event)='change_user' AND $(ev conn)=$CU_CONN AND $(ev status)='0'") = 1;"
    check "change_user names the account BEFORE the switch (ca_test_user, not ca_test_cu)" \
        "SELECT $(count_where "$(ev event)='change_user' AND $(ev conn)=$CU_CONN AND $(ev user)='ca_test_user' AND $(ev user_context)='before_change'") = 1;"
    check "failed switch recorded as change_user_failed, status 1045" \
        "SELECT $(count_where "$(ev event)='change_user_failed' AND $(ev conn)=$CU_CONN AND $(ev status)='1045'") = 1;"
    check "change_user_failed names the current account (ca_test_cu), not the attempted one (ca_test_user)" \
        "SELECT $(count_where "$(ev event)='change_user_failed' AND $(ev conn)=$CU_CONN AND $(ev user)='ca_test_cu'") = 1;"
    check "the connection's later disconnect carries the new account" \
        "SELECT $(count_where "$(ev event)='disconnect' AND $(ev conn)=$CU_CONN AND $(ev user)='ca_test_cu'") = 1;"
    sql "SET GLOBAL campus_audit_connections = 'FAILED';"
    out=$(run_change_user)
    CU_CONN2=$(printf '%s\n' "$out" | awk '$1 == "CONN" {print $2}' | tr -d '\r')
    CU_CONN2=${CU_CONN2:-0}
    check "connections=FAILED records only the failed switch" \
        "SELECT $(count_where "$(ev conn)=$CU_CONN2 AND $(ev event)='change_user'") = 0 AND $(count_where "$(ev conn)=$CU_CONN2 AND $(ev event)='change_user_failed'") = 1;"
    check "no COM_CHANGE_USER password appears in the log" \
        "SELECT $(count_where "line LIKE '%campus-audit-wrong-password%' OR line LIKE '%$TEST_PW%'") = 0;"
else
    skip "CHANGE_USER (set CHANGE_USER_CLIENT to the campus_change_user helper; make test-e2e does)"
fi

check "configuration changes are recorded as config_change" \
    "SELECT $(count_where "$(ev event)='config_change' AND $(ev variable)='campus_audit_databases' AND $(ev value)='*'") = 1;"
check "the SET statement of a configuration change is attributed to the account" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev sql_digest) LIKE 'SET GLOBAL campus_audit_databases = ?%'") >= 1;"

# ---------------------------------------------------------------- concurrency

echo "-- concurrency ($CLIENTS clients x $PER_CLIENT inserts)"
sql "CREATE TABLE audit_test_watched.load_t (c INT, i INT, PRIMARY KEY (c, i));"
for c in $(seq 1 "$CLIENTS"); do
    stmts=""
    for i in $(seq 1 "$PER_CLIENT"); do stmts+="INSERT INTO audit_test_watched.load_t VALUES ($c, $i);"; done
    sql "$stmts" >/dev/null &
done
wait
total=$((CLIENTS * PER_CLIENT))
check "all $total concurrent inserts recorded as table_write" \
    "SELECT $(count_where "$(ev event)='table_write' AND $(ev table)='load_t'") = $total;"
check "all $total concurrent statements recorded" \
    "SELECT $(count_where "$(ev event)='statement' AND $(ev sql_digest)='INSERT INTO audit_test_watched.load_t VALUES (?, ?)'") = $total;"
check "no torn or interleaved lines under concurrency" "SELECT $(count_where "NOT JSON_VALID(line)") = 0;"
check "seq values are unique" \
    "SELECT COUNT(*) = COUNT(DISTINCT JSON_VALUE(line,'\$.seq')) FROM campus_audit_test.log_lines;"

# ---------------------------------------------------------------- write failure (fail-open)

echo "-- I/O failure behaviour"
if [ "$OS" != "Win64" ] && sql "SET GLOBAL campus_audit_file_path = '/dev/full';" 2>/dev/null; then
    out=$(sql "INSERT INTO audit_test_watched.rooms_renamed (id, name, capacity) VALUES (20, 'during outage', 1); SELECT 'ok';" 2>&1)
    [ "$out" = "ok" ] && pass "statement succeeds while the audit log cannot be written (fail-open)" \
        || fail "statement succeeds while the audit log cannot be written (fail-open)" "got: $out"
    check "state becomes DEGRADED" "SELECT VARIABLE_VALUE='DEGRADED' FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_STATE';"
    check "write_failures counted" "SELECT VARIABLE_VALUE > 0 FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_WRITE_FAILURES';"
    check "last_error explains the failure" "SELECT VARIABLE_VALUE LIKE '%errno%' FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_LAST_ERROR';"
    sql "SELECT SLEEP(6);" >/dev/null
    sql "INSERT INTO audit_test_watched.rooms_renamed (id, name, capacity) VALUES (21, 'recovery attempt', 1); SELECT 'ok';" >/dev/null
    check "failed recovery-marker write keeps the plugin DEGRADED" "SELECT VARIABLE_VALUE='DEGRADED' FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_STATE';"
    check "failed recovery-marker write is counted" "SELECT VARIABLE_VALUE >= 2 FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_WRITE_FAILURES';"
    sql "SET GLOBAL campus_audit_file_path = $LOG_EXPR;"
    check "switching to a writable file restores ACTIVE" "SELECT VARIABLE_VALUE='ACTIVE' FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_STATE';"
    check "the outage is announced by an audit_gap record" "SELECT $(count_where "$(ev event)='audit_gap' AND $(ev dropped_events) > 0") = 1;"
    check "the row written during the outage exists" "SELECT COUNT(*) = 1 FROM audit_test_watched.rooms_renamed WHERE id = 20;"
else
    skip "write failure via /dev/full (Linux only; see docs/experiments.md for the Windows lock experiment)"
fi

# ---------------------------------------------------------------- reopen / rotation

sql "SET GLOBAL campus_audit_reopen_now = ON;"
check "reopen_now reads back OFF" "SELECT @@GLOBAL.campus_audit_reopen_now = 0;"
check "reopen_now is recorded" "SELECT $(count_where "$(ev event)='config_change' AND $(ev variable)='campus_audit_reopen_now'") = 1;"
sql "SET GLOBAL campus_audit_file_path = $LOG2_EXPR;"
sql "SET GLOBAL campus_audit_file_path = $LOG_EXPR;"
check "switching files records the previous path" \
    "SELECT $(count_where "$(ev event)='config_change' AND $(ev variable)='campus_audit_file_path' AND $(ev value) LIKE '%(previous: %_b.jsonl)'") = 1;"

# ---------------------------------------------------------------- trigger interplay

echo "-- interaction with SQL triggers"
if [ "$(sql "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='university_resources' AND TRIGGER_NAME='trg_rooms_audit_update';")" = "1" ]; then
    sql "SET GLOBAL campus_audit_databases = 'university_resources';"
    C2=$(sql "SET @app_user_id = (SELECT user_id FROM university_resources.users ORDER BY user_id LIMIT 1);
              UPDATE university_resources.rooms SET capacity = capacity WHERE room_id = (SELECT MIN(room_id) FROM university_resources.rooms);
              UPDATE university_resources.rooms SET location_details = CONCAT(COALESCE(location_details,''), '') WHERE room_id = (SELECT MIN(room_id) FROM university_resources.rooms);
              SELECT CONNECTION_ID();" | tail -1)
    reload_log
    check "plugin sees the trigger's write to audit_events in the same statement" \
        "SELECT COUNT(*) >= 1 FROM campus_audit_test.log_lines a JOIN campus_audit_test.log_lines r
           ON JSON_VALUE(a.line,'\$.query_id') = JSON_VALUE(r.line,'\$.query_id')
          WHERE JSON_VALUE(a.line,'\$.table')='audit_events' AND JSON_VALUE(r.line,'\$.table')='rooms'
            AND JSON_VALUE(a.line,'\$.conn')='$C2';"
    check "trigger row carries the application user and connection id" \
        "SELECT COUNT(*) >= 1 FROM university_resources.audit_events WHERE connection_id = $C2 AND event_source = 'application' AND application_user_id IS NOT NULL;"
    sql "SET GLOBAL campus_audit_databases = 'audit_test_watched';"
else
    skip "trigger interplay (university_resources with triggers not installed)"
fi

# ---------------------------------------------------------------- lifecycle

echo "-- install / uninstall"
expect_error "second INSTALL PLUGIN of the same plugin rejected" 1968 "INSTALL PLUGIN campus_audit SONAME 'campus_audit';"
out=$(sql "INSTALL SONAME 'campus_audit'; SELECT 'no error';" 2>&1)
if [ "$out" = "no error" ]; then
    pass "INSTALL SONAME of an installed library is a silent no-op (observed server behaviour)"
else
    fail "INSTALL SONAME of an installed library is a silent no-op (observed server behaviour)" "got: $out"
fi
expect_error "INSTALL of a missing library fails cleanly" 1126 "INSTALL SONAME 'campus_audit_missing_$RUN_ID';"
INSTANCE=$(sql "CALL campus_audit_test.load_log($LOG_EXPR); SELECT JSON_VALUE(line,'\$.instance') FROM campus_audit_test.log_lines ORDER BY start_pos DESC LIMIT 1;" | tail -1)
sql "UNINSTALL SONAME 'campus_audit';"
check "UNINSTALL removes the plugin" "SELECT COUNT(*) = 0 FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';"
check "deinit wrote plugin_stop with counters" \
    "SELECT $(count_where "$(ev event)='plugin_stop' AND $(ev instance)='$INSTANCE' AND $(ev events_written) > 0") = 1;"
lines_before=$(count_where 1)
sql "INSERT INTO audit_test_watched.rooms_renamed (id, name, capacity) VALUES (30, 'while uninstalled', 1);"
check "nothing is recorded while uninstalled" "SELECT $(count_where 1) = $lines_before;"
expect_error "second UNINSTALL rejected" 1305 "UNINSTALL SONAME 'campus_audit';"
sql "INSTALL SONAME 'campus_audit';"
check "re-INSTALL makes the plugin ACTIVE again" "SELECT PLUGIN_STATUS='ACTIVE' FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';"
sql "SET GLOBAL campus_audit_file_path = $LOG_EXPR;"
check "re-INSTALL starts a new instance (new instance id)" \
    "SELECT $(count_where "$(ev event)='config_change' AND $(ev instance)<>'$INSTANCE'") >= 1;"

# ---------------------------------------------------------------- summary

echo "== $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
