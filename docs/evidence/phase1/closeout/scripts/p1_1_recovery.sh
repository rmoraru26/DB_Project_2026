#!/usr/bin/env bash
# Closeout verification of P1-1 (oversized log recovery) in a throw-away
# MariaDB 13.0.2 container.  Not part of the test suite; run from the
# repository root:
#
#   bash docs/evidence/phase1/closeout/scripts/p1_1_recovery.sh <image> <pre-fix rotate_log.sh>
#
# Scenarios
#   A. the state the audit described: an oversized log rotated by the PRE-FIX
#      script, whose archive import fails and leaves the archive behind; then
#      the DOCUMENTED recovery (docs/docker.md: make import-log FILE=<archive>,
#      i.e. rotate_log.sh --import <archive>) with the CURRENT script;
#   B. a failure in the middle of a parts import (plugin_events locked by
#      another session, lock_wait_timeout = 2): exit 1, archive unchanged, no
#      part left; the same command afterwards succeeds;
#   C. a rotation whose reopen fails (log directory not writable for the
#      server): the rename is undone, the original file is reopened at once,
#      the active log keeps every earlier record and receives new ones.
#      (The first run, 06a, found that the pre-fix rotate_log.sh left the
#      plugin DEGRADED after undoing the rename; fixed in rotate_log.sh.)
# Every check compares line counts of the files with rows in plugin_events
# and SHA-256 of the archive.  The passwords exist only in this container.
set -u
IMAGE=$1; OLD=$2; N=frt-closeout-p11-$$
trap 'docker rm -f -v $N >/dev/null 2>&1' EXIT
MSYS_NO_PATHCONV=1 docker run -d --name $N -e MARIADB_ROOT_PASSWORD=closeRootPw123 -e CAMPUS_APP_PASSWORD=closeAppPw1234 "$IMAGE" >/dev/null
for i in $(seq 1 90); do
    r=$(docker exec -e MYSQL_PWD=closeRootPw123 $N mariadb -uroot -N -e "SELECT COUNT(*) FROM mysql.user WHERE user='campus_app'" 2>/dev/null | tr -d '\r')
    [ "$r" = 1 ] && break; sleep 2
done
sleep 8
put() { tr -d '\r' < "$1" | MSYS_NO_PATHCONV=1 docker exec -i $N bash -c "mkdir -p \"\$(dirname '$2')\" && cat > '$2'"; }
put scripts/rotate_log.sh /opt/new/rotate_log.sh
put scripts/mariadb_admin_auth.sh /opt/new/mariadb_admin_auth.sh
put "$OLD" /opt/old/rotate_log.sh
put scripts/mariadb_admin_auth.sh /opt/old/mariadb_admin_auth.sh
put database/migrations/008_import_plugin_log_errors.sql /opt/new/008.sql

MSYS_NO_PATHCONV=1 docker exec -i -e MYSQL_PWD=closeRootPw123 $N bash -s 2>&1 <<'EOF'
set -u
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
q() { printf '%s\n' "$1" | mariadb -uroot --batch --skip-column-names 2>&1; }
D=/var/log/campus_audit; LOG=$D/campus_audit.jsonl
for _ in $(seq 1 60); do [ "$(q 'SELECT 1;')" = 1 ] && break; sleep 1; done
q "INSTALL SONAME 'campus_audit';" >/dev/null
mariadb -uroot < /opt/new/008.sql
instance=$(tail -n 1 "$LOG" | sed -n 's/.*"instance":"\([^"]*\)".*/\1/p')
write_records() { local i s=""; for i in $(seq 1 "$1"); do s="$s UPDATE university_resources.rooms SET capacity = capacity WHERE room_id = 0 AND name = 'closeout-$i';"; done; q "$s" >/dev/null; }
rows() { q "SELECT COUNT(*) FROM campus_audit.plugin_events WHERE instance_id = '$instance';"; }
lines_of() { cat "$@" | grep -c "\"instance\":\"$instance\""; }
no_parts() { [ -z "$(find "$D" -maxdepth 1 -name '.import-parts.*' -print -quit)" ]; }
echo "server $(q 'SELECT @@version;'), plugin instance $instance"

# ---------------------------------------------------------------- A
q "SET GLOBAL max_allowed_packet = 65536;" >/dev/null
write_records 150
echo "active log: $(stat -c %s $LOG) bytes, limit 65536"
out=$(bash /opt/old/rotate_log.sh 2>&1); st=$?
old_archive=$(printf '%s\n' "$out" | sed -n 's/^Rotated: \(.*\.jsonl\) (.*/\1/p')
if [ "$st" -ne 0 ] && [ -n "$old_archive" ] && [ -f "$old_archive" ] && [ "$(stat -c %s "$old_archive")" -ge 65536 ]; then
    pass "pre-fix script: rotation done, archive import FAILED (exit $st), oversized archive left at $old_archive ($(stat -c %s "$old_archive") bytes)"
else fail "pre-fix script did not reproduce the audited state" "exit $st: $out"; fi
in_old=$(lines_of "$old_archive")
echo "records in that archive: $in_old; rows in plugin_events so far: $(rows)"
sum=$(sha256sum "$old_archive" | cut -d' ' -f1)
sleep 1.1
out=$(bash /opt/new/rotate_log.sh --import "$old_archive" 2>&1); st=$?
echo "$out" | sed 's/^/      | /'
if [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q "in [0-9]* parts"; then pass "documented recovery (rotate_log.sh --import <archive>) exits 0 and imports in parts"
else fail "documented recovery" "exit $st"; fi
q "CALL campus_audit.import_plugin_log('$LOG');" >/dev/null
if [ "$(lines_of "$old_archive" "$LOG")" = "$(rows)" ]; then pass "after the recovery every record of the archive and the active log is in plugin_events once ($(rows))"
else fail "records after recovery" "files $(lines_of "$old_archive" "$LOG"), rows $(rows)"; fi
if [ "$(sha256sum "$old_archive" | cut -d' ' -f1)" = "$sum" ] && no_parts; then pass "the archive is unchanged (SHA-256) and no part file is left"
else fail "archive changed or parts left"; fi

# ---------------------------------------------------------------- B
write_records 150
sleep 1.1
q "SET GLOBAL lock_wait_timeout = 2;" >/dev/null
before_rows=$(rows)
# Hold a write lock on plugin_events in another session while rotating.
printf 'LOCK TABLES campus_audit.plugin_events WRITE; SELECT SLEEP(25);\n' | mariadb -uroot >/dev/null 2>&1 & holder=$!
sleep 1
out=$(bash /opt/new/rotate_log.sh 2>&1); st=$?
archive_b=$(printf '%s\n' "$out" | sed -n 's/^Rotated: \(.*\.jsonl\) (.*/\1/p')
kill $holder 2>/dev/null; wait $holder 2>/dev/null
q "SET GLOBAL lock_wait_timeout = 31536000;" >/dev/null
echo "$out" | sed 's/^/      | /'
if [ "$st" -eq 1 ] && [ -n "$archive_b" ] && printf '%s' "$out" | grep -q "rotate_log.sh --import '$archive_b'"; then
    pass "import failure in the middle (plugin_events locked): exit 1, and the message names the retry command"
else fail "failure in the middle" "exit $st"; fi
sum_b=$(sha256sum "$archive_b" | cut -d' ' -f1)
if [ -f "$archive_b" ] && [ -f "$LOG" ] && no_parts && [ "$(rows)" = "$before_rows" ]; then
    pass "after that failure: archive and new active log exist, no part file is left, nothing was imported"
else fail "state after the failure" "rows $(rows) vs $before_rows"; fi
out=$(bash /opt/new/rotate_log.sh --import "$archive_b" 2>&1); st=$?
q "CALL campus_audit.import_plugin_log('$LOG');" >/dev/null
if [ "$st" -eq 0 ] && [ "$(lines_of "$old_archive" "$archive_b" "$LOG")" = "$(rows)" ] && [ "$(sha256sum "$archive_b" | cut -d' ' -f1)" = "$sum_b" ]; then
    pass "the named retry imports everything: $(rows) records in the files and in plugin_events; archive unchanged"
else fail "retry after the failure" "exit $st, files $(lines_of "$old_archive" "$archive_b" "$LOG"), rows $(rows)"; fi

# ---------------------------------------------------------------- C
write_records 10
lines_before=$(lines_of "$LOG")
chmod 0550 "$D"            # the server (owner mysql) can no longer create the new file
sleep 1.1
out=$(bash /opt/new/rotate_log.sh 2>&1); st=$?
chmod 0750 "$D"
echo "$out" | sed 's/^/      | /'
if [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q "the rename was undone and the plugin writes to $LOG again" && [ -f "$LOG" ] \
   && [ -z "$(find "$D" -maxdepth 1 -name 'campus_audit-*.jsonl' -newer "$archive_b" -print -quit)" ]; then
    pass "reopen failure: exit 1, the rename was undone, no new archive name is left"
else fail "reopen failure" "exit $st"; fi
write_records 1
if [ "$(lines_of "$LOG")" -gt "$lines_before" ]; then pass "the active log keeps every earlier record and still receives new ones ($(lines_of "$LOG") lines)"
else fail "active log after the reopen failure"; fi
q "SET GLOBAL campus_audit_reopen_now = ON;" >/dev/null
state=$(q "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'CAMPUS_AUDIT_STATE';")
if [ "$state" = ACTIVE ]; then pass "after the directory is writable again a reopen succeeds; plugin ACTIVE"; else fail "plugin state" "$state"; fi

q "SET GLOBAL max_allowed_packet = 16777216;" >/dev/null
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
EOF
