#!/usr/bin/env bash
# Log rotation against the RUNNING Docker stack: scripts/rotate_log.sh renames
# the plugin's log inside the mariadb container, makes the plugin reopen it
# and imports both files.  The test proves that no record is lost and none is
# imported twice.
#
#   make up && bash tests/integration/test_log_rotation.sh
#
# It runs on the machine that ran `make up` (needs Docker Compose).  Effects on
# the stack: the audit log is rotated twice; the two archived files
# (campus_audit-<UTC time>.jsonl) stay in the audit-log volume, as after any
# rotation.  No audit record is deleted.
set -u
cd "$(dirname "$0")/../.."
COMPOSE=(${COMPOSE:-docker compose})
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

[ -f .env ] || { echo "test_log_rotation: .env not found; run make up first" >&2; exit 2; }
root_password=$(sed -n 's/^MARIADB_ROOT_PASSWORD=//p' .env | tail -n 1)
in_db() { MSYS_NO_PATHCONV=1 "${COMPOSE[@]}" exec -T mariadb "$@" 2>&1 | tr -d '\r'; }
sql() { MYSQL_PWD=$root_password MSYS_NO_PATHCONV=1 "${COMPOSE[@]}" exec -T -e MYSQL_PWD mariadb mariadb -uroot --batch --skip-column-names -e "$1" 2>&1 | tr -d '\r'; }
rotate() { MSYS_NO_PATHCONV=1 "${COMPOSE[@]}" exec -T mariadb bash /usr/local/share/campus/scripts/rotate_log.sh 2>&1 | tr -d '\r'; }
# A statement the plugin records (table_write + statement) without changing a row.
marker() { sql "UPDATE university_resources.rooms SET capacity = capacity WHERE room_id = 0 AND name = 'rotation-marker-$1';" >/dev/null; }
marker_imported() { sql "SELECT COUNT(*) FROM campus_audit.plugin_events WHERE event_type = 'statement' AND sql_digest = 'UPDATE university_resources.rooms SET capacity = capacity WHERE room_id = ? AND name = ?' AND event_time >= '$1';"; }

LOG=$(sql "SELECT @@GLOBAL.campus_audit_file_path;")
case "$LOG" in /*.jsonl) ;; *) echo "test_log_rotation: unexpected log path '$LOG'" >&2; exit 2 ;; esac
instance=$(in_db tail -n 1 "$LOG" | sed -n 's/.*"instance":"\([^"]*\)".*/\1/p')
started=$(sql "SELECT UTC_TIMESTAMP(6);")
[ -n "$instance" ] || { echo "test_log_rotation: cannot read the plugin instance from $LOG" >&2; exit 2; }

marker before
lines_before=$(in_db grep -c "\"instance\":\"$instance\"" "$LOG")
out=$(rotate); status=$?
archive=$(printf '%s\n' "$out" | sed -n 's/^Rotated: \(.*\.jsonl\) (.*/\1/p')
if [ "$status" -eq 0 ] && [ -n "$archive" ] && printf '%s' "$out" | grep -q "Imported the archived file" && printf '%s' "$out" | grep -q "Imported the new file"; then
    pass "rotate_log.sh renames the log, reopens it and imports both files"
else fail "rotate_log.sh" "$out"; fi
if [ "$(in_db test -f "$archive" && echo yes)" = yes ] && [ "$(in_db test -f "$LOG" && echo yes)" = yes ] \
   && [ "$(sql "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'CAMPUS_AUDIT_STATE';")" = ACTIVE ]; then
    pass "the archived file and a new active file exist; the plugin is ACTIVE"
else fail "files after rotation"; fi
if [ "$(in_db stat -c '%U:%G %a' "$LOG")" = "$(in_db stat -c '%U:%G %a' "$archive")" ]; then
    pass "the new log has the owner and mode of the old one ($(in_db stat -c '%U:%G %a' "$LOG"))"
else fail "owner and mode of the new log" "$(in_db stat -c '%U:%G %a' "$LOG") vs $(in_db stat -c '%U:%G %a' "$archive")"; fi
archived_lines=$(in_db grep -c "\"instance\":\"$instance\"" "$archive")
if [ "$archived_lines" -ge "$lines_before" ] && [ "$(in_db grep -c '"event":"config_change","variable":"campus_audit_reopen_now"' "$LOG")" -ge 1 ]; then
    pass "the archived file holds every earlier record ($archived_lines lines of this plugin instance); the new file starts with the reopen record"
else fail "contents after rotation" "archived $archived_lines, before $lines_before"; fi

marker after
sql "CALL campus_audit.import_plugin_log('$LOG');" >/dev/null
if [ "$(marker_imported "$started")" = 2 ]; then pass "the statement written before the rotation and the one written after it are both in plugin_events, once each"
else fail "records around the rotation" "found $(marker_imported "$started"), expected 2"; fi
# Exactly the records of the two files: an earlier rotation of the same plugin
# instance (e.g. a second run of this test) leaves further rows of that
# instance in plugin_events, which belong to older archives.
seqs=$(in_db bash -c "cat '$archive' '$LOG' | grep '\"instance\":\"$instance\"' | sed -n 's/.*\"seq\":\([0-9]*\).*/\1/p'")
in_files=$(printf '%s\n' "$seqs" | grep -c '[0-9]')
distinct=$(printf '%s\n' "$seqs" | grep '[0-9]' | sort -u | wc -l | tr -d ' ')
in_table=$(sql "SELECT COUNT(*) FROM campus_audit.plugin_events WHERE instance_id = '$instance' AND seq IN ($(printf '%s\n' "$seqs" | grep '[0-9]' | paste -sd, -));")
if [ "$in_files" -gt 0 ] && [ "$in_files" = "$distinct" ] && [ "$in_files" = "$in_table" ]; then pass "no record lost and none duplicated: $in_files lines in the two files, each of their seq values exactly once in plugin_events"
else fail "lines in the files vs rows in plugin_events" "files $in_files (distinct seq $distinct), matching rows $in_table"; fi

sleep 1
out=$(rotate); status=$?
archive2=$(printf '%s\n' "$out" | sed -n 's/^Rotated: \(.*\.jsonl\) (.*/\1/p')
if [ "$status" -eq 0 ] && [ -n "$archive2" ] && [ "$archive2" != "$archive" ] && [ "$(in_db test -f "$archive" && echo yes)" = yes ]; then
    pass "a second rotation creates a second archive and keeps the first"
else fail "second rotation" "$out"; fi
again=$(sql "CALL campus_audit.import_plugin_log('$archive'); CALL campus_audit.import_plugin_log('$archive2');" | cut -f4 | tr '\n' ' ')
if [ "$again" = "0 0 " ]; then pass "re-importing the archived files adds nothing"
else fail "re-import of the archives" "$again"; fi

echo "== $PASS passed, $FAIL failed   (archives kept: $archive $archive2)"
[ "$FAIL" -eq 0 ]
