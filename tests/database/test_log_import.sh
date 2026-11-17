#!/usr/bin/env bash
# campus_audit.import_plugin_log() on the server: results, limits and error
# paths (migrations 002 and 008).
#
#   1. importing the plugin's current log works and a second import adds
#      nothing; the caller's session time_zone and max_recursive_iterations
#      are as before;
#   2. an empty path and a missing file fail with ER 1644 and leave the
#      session untouched;
#   3. a failure in the middle (a lock wait timeout on plugin_events, ER 1205)
#      reports that same error, restores the session time_zone and
#      max_recursive_iterations and leaves no temporary table behind;
#   4. a log larger than max_allowed_packet is refused with a message that
#      names the limit and the remedy.  For this one check the GLOBAL
#      max_allowed_packet is lowered below the size of the log and restored
#      immediately afterwards; connections opened in those few seconds get the
#      lower limit, so run the test on a development server only;
#   5. unterminated and invalid lines are skipped and counted (uses a small
#      file written with SELECT ... INTO DUMPFILE into the log directory;
#      like the plugin harness's test logs it stays there, a few hundred bytes).
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/test_log_import.sh
#
# ADMINISTRATOR ACCESS (FILE, SUPER).  Needs the campus_audit plugin ACTIVE;
# without it the test reports SKIP.  Rotation by renaming the file needs
# access to the server's file system and is tested by
# tests/integration/test_log_rotation.sh.

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }
# One connection per call; --force so that the statements after a failing
# CALL still run and can report the state of that same session.
session() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names --force 2>&1 | tr -d '\r'; }
has() { printf '%s' "$out" | grep -qF -- "$1"; }

if [ "$(session "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';")" != ACTIVE ]; then
    echo "SKIP: the campus_audit plugin is not ACTIVE on this server; nothing to import"
    exit 0
fi
LOG=$(session "SELECT @@GLOBAL.campus_audit_file_path;")
ORIG_PACKET=$(session "SELECT @@GLOBAL.max_allowed_packet;")
restore() { session "SET GLOBAL max_allowed_packet = $ORIG_PACKET;" >/dev/null 2>&1; }
trap restore EXIT
case "$LOG" in *"'"*|*'\'*) echo "SKIP: the log path contains a quote or backslash"; exit 0 ;; esac
STATE="SELECT CONCAT('state=', @@SESSION.time_zone, '|', @@SESSION.max_recursive_iterations, '|', (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'campus_audit' AND TABLE_NAME = 'tmp_plugin_lines'));"
PREPARE="SET SESSION time_zone = '+05:30'; SET SESSION max_recursive_iterations = 4321;"
EXPECTED_STATE="state=+05:30|4321|0"
temporary_left() {   # a temporary table is invisible in information_schema; ask the session itself
    printf '%s' "$1" | grep -q "^tmp_plugin_lines$"
}

# ---------------------------------------------------------------- 1. normal import
out=$(session "$PREPARE CALL campus_audit.import_plugin_log('$LOG'); CALL campus_audit.import_plugin_log('$LOG'); $STATE SHOW TABLES FROM campus_audit LIKE 'tmp_plugin_lines';")
first=$(printf '%s\n' "$out" | sed -n 1p); second=$(printf '%s\n' "$out" | sed -n 2p)
if printf '%s' "$first" | grep -Eq "^[^	]*campus_audit[^	]*	[0-9]+	[0-9]+	[0-9]+$" && [ "$(printf '%s' "$first" | cut -f2)" -gt 0 ]; then
    pass "import of the current log returns log_file, total_lines, invalid_lines_skipped, newly_imported ($(printf '%s' "$first" | cut -f2) lines)"
else fail "import of the current log" "$out"; fi
if [ "$(printf '%s' "$second" | cut -f4)" = 0 ] && [ "$(printf '%s' "$second" | cut -f2)" -ge "$(printf '%s' "$first" | cut -f2)" ]; then
    pass "an immediate second import reads the whole file again and adds nothing"
else fail "an immediate second import adds nothing" "$second"; fi
if has "$EXPECTED_STATE" && ! temporary_left "$out"; then pass "after a successful import the session time_zone and max_recursive_iterations are as before; no temporary table remains"
else fail "session state after a successful import" "$out"; fi
out=$(session "SELECT COUNT(*) = COUNT(DISTINCT instance_id, seq) AND COUNT(*) > 0 AND SUM(record IS NULL OR NOT JSON_VALID(record)) = 0 FROM campus_audit.plugin_events;")
if [ "$out" = 1 ]; then pass "plugin_events holds each (instance, seq) once, with its complete JSON record"
else fail "plugin_events content" "$out"; fi

# ---------------------------------------------------------------- 2. refused before anything is changed
out=$(session "$PREPARE CALL campus_audit.import_plugin_log(''); CALL campus_audit.import_plugin_log(NULL); $STATE")
if [ "$(printf '%s\n' "$out" | grep -c "^ERROR 1644 .*the log path is empty")" = 2 ] && has "$EXPECTED_STATE"; then
    pass "an empty or NULL path is refused (ER 1644); the session is untouched"
else fail "empty path" "$out"; fi
out=$(session "$PREPARE CALL campus_audit.import_plugin_log('${LOG}.does-not-exist'); $STATE SHOW TABLES FROM campus_audit LIKE 'tmp_plugin_lines';")
if has "ERROR 1644" && has "LOAD_FILE returned NULL" && has "$EXPECTED_STATE" && ! temporary_left "$out"; then
    pass "a missing file is refused (ER 1644, LOAD_FILE returned NULL); the session is untouched"
else fail "missing file" "$out"; fi

# ---------------------------------------------------------------- 3. failure in the middle
# Another connection holds a table lock on plugin_events while this one
# imports with a one-second lock wait: the INSERT into plugin_events fails
# after the procedure has switched the session time zone.
( session "LOCK TABLES campus_audit.plugin_events WRITE; SELECT SLEEP(7); UNLOCK TABLES;" >/dev/null ) &
blocker=$!
sleep 2
out=$(session "$PREPARE SET SESSION lock_wait_timeout = 1; SET SESSION innodb_lock_wait_timeout = 1;
               CALL campus_audit.import_plugin_log('$LOG'); $STATE SHOW TABLES FROM campus_audit LIKE 'tmp_plugin_lines';")
wait "$blocker"
if has "ERROR 1205"; then pass "a lock wait timeout during the import is reported as that error (ER 1205), not replaced by another"
else fail "the mid-import failure is reported as ER 1205" "$out"; fi
if has "$EXPECTED_STATE"; then pass "after the failed import the session time_zone (+05:30) and max_recursive_iterations (4321) are restored"
else fail "session state after a failed import (migration 008)" "$(printf '%s' "$out" | grep '^state=')"; fi
if ! temporary_left "$out"; then pass "after the failed import no temporary table is left in the session"
else fail "temporary table left behind after a failed import"; fi
out=$(session "CALL campus_audit.import_plugin_log('$LOG');")
if printf '%s' "$out" | grep -Eq "	[0-9]+	[0-9]+	[0-9]+$"; then pass "the next import succeeds; nothing was left half-done"
else fail "import after the failed one" "$out"; fi

# ---------------------------------------------------------------- 4. larger than max_allowed_packet
size=$(session "SELECT LENGTH(LOAD_FILE('$LOG'));")
if printf '%s' "$size" | grep -Eq '^[0-9]+$' && [ "$size" -gt 4096 ]; then
    limit=$(( (size / 2 / 1024) * 1024 ))
    session "SET GLOBAL max_allowed_packet = $limit;" >/dev/null
    out=$(session "$PREPARE SELECT CONCAT('limit=', @@SESSION.max_allowed_packet); CALL campus_audit.import_plugin_log('$LOG'); $STATE")
    restore
    if has "limit=$limit" && has "ERROR 1644" && has "not smaller than max_allowed_packet" && has "rotate_log.sh" && has "make import-log"; then
        pass "a log of $size bytes with max_allowed_packet = $limit is refused with the limit and the remedy (import in parts with rotate_log.sh) in the message"
    else fail "log larger than max_allowed_packet" "$out"; fi
    if has "$EXPECTED_STATE"; then pass "that refusal leaves the session untouched"; else fail "session state after the size refusal" "$out"; fi
    if [ "$(session "SELECT @@GLOBAL.max_allowed_packet;")" = "$ORIG_PACKET" ]; then pass "the global max_allowed_packet is back at $ORIG_PACKET"
    else fail "the global max_allowed_packet was not restored"; fi
    out=$(session "CALL campus_audit.import_plugin_log('$LOG');")
    if printf '%s' "$out" | grep -Eq "	[0-9]+	[0-9]+	[0-9]+$"; then pass "with the original limit the same file imports again"
    else fail "import after restoring max_allowed_packet" "$out"; fi
else
    skip "size limit (the current log is too small to go below it: ${size:-unknown} bytes)"
fi

# ---------------------------------------------------------------- 5. invalid and unterminated lines
case "$LOG" in
    /*)
        dir=${LOG%/*}
        file="$dir/frt_import_test_$(date +%s)_$$.jsonl"
        instance="import-test-$$"
        # line 1 valid, line 2 not JSON, line 3 valid JSON without instance/seq,
        # line 4 valid, line 5 valid but without a final newline (still being written)
        out=$(session "SELECT CONCAT(
                '{\"ts\":\"2026-01-02T03:04:05.123456Z\",\"seq\":1,\"instance\":\"$instance\",\"event\":\"table_write\",\"conn\":7,\"query_id\":9,\"user\":\"u\",\"db\":\"d\",\"table\":\"t\"}', CHAR(10),
                'this line is not JSON', CHAR(10),
                '{\"note\":\"valid JSON, but not a plugin record\"}', CHAR(10),
                '{\"ts\":\"2026-01-02T03:04:06.000001Z\",\"seq\":2,\"instance\":\"$instance\",\"event\":\"statement\",\"conn\":7,\"query_id\":9,\"account\":\"u[u] @ h []\",\"error_code\":1062,\"status\":\"error\",\"scope\":\"session\",\"sql_digest\":\"INSERT INTO t VALUES (?)\"}', CHAR(10),
                '{\"ts\":\"2026-01-02T03:04:07.000000Z\",\"seq\":3,\"instance\":\"$instance\",\"event\":\"table_write\"')
              INTO DUMPFILE '$file';")
        if [ -n "$out" ]; then
            skip "invalid and unterminated lines (could not write a test file into $dir: $(printf '%s' "$out" | head -n 1))"
        else
            out=$(session "CALL campus_audit.import_plugin_log('$file');")
            if [ "$(printf '%s' "$out" | cut -f2-4)" = "4	1	2" ]; then
                pass "4 complete lines read, 1 invalid line skipped and counted, 2 records imported; the unterminated last line is left for the next import"
            else fail "invalid and unterminated lines" "$out"; fi
            out=$(session "SET time_zone = '+00:00';
                           SELECT CONCAT_WS('|', event_type, connection_id, query_id, db_user, status_code, schema_name, table_name, event_time, JSON_VALUE(record, '\$.scope'))
                             FROM campus_audit.plugin_events WHERE instance_id = '$instance' ORDER BY seq;")
            expected="table_write|7|9|u|d|t|2026-01-02 03:04:05.123456
statement|7|9|u[u] @ h []|1062|2026-01-02 03:04:06.000001|session"
            if [ "$out" = "$expected" ]; then pass "the imported columns hold the record's values; event_time is the record's UTC time; unknown fields such as scope stay in the JSON record"
            else fail "imported column values" "$out"; fi
            session "DELETE FROM campus_audit.plugin_events WHERE instance_id = '$instance';" >/dev/null
        fi ;;
    *) skip "invalid and unterminated lines (the log path is relative; this part needs an absolute log directory)" ;;
esac

echo "== $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
