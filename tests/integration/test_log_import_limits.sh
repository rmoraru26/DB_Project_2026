#!/usr/bin/env bash
# Log rotation and the import of files at or above max_allowed_packet, in a
# throw-away server container (the running stack is not touched).
#
#   make test-integration          (or: bash tests/integration/test_log_import_limits.sh)
#
# The container is started from the stack's MariaDB image (make up builds it;
# LOG_LIMITS_IMAGE=<image> chooses another one).  The working tree's
# scripts/rotate_log.sh, scripts/mariadb_admin_auth.sh and migration 008 are
# copied into it, so the test checks this checkout, not the copies baked into
# the image.  It has no published port and its own anonymous volume; both are
# removed at the end.
#
# What it proves:
#   1. ordinary rotation: rename, reopen, import of both files, nothing lost or
#      duplicated, no temporary file left;
#   2. a log that has grown to max_allowed_packet or beyond is refused by
#      import_plugin_log() with the remedy in the message;
#   3. rotating it still imports everything: the oversized archive is imported
#      in line-aligned parts; the archive is not modified; nothing is lost or
#      duplicated; no part file is left;
#   4. `rotate_log.sh --import` re-imports an archive (adds nothing) and is the
#      documented recovery for an archive whose import failed;
#   5. the documented alternative works: SET GLOBAL max_allowed_packet above
#      the file size, then a NEW connection can import the file in one call;
#   6. a file with a single line at or above the limit is refused BEFORE any
#      import, with an actionable message, and stays unchanged;
#   7. a missing file is refused with exit status 1.
set -u
cd "$(dirname "$0")/../.."
COMPOSE=(${COMPOSE:-docker compose})
NAME="campus-audit-loglimits-$$-$RANDOM"

IMAGE=${LOG_LIMITS_IMAGE:-}
if [ -z "$IMAGE" ]; then
    running=$("${COMPOSE[@]}" ps -q mariadb 2>/dev/null | head -n 1)
    [ -n "$running" ] && IMAGE=$(docker inspect --format '{{.Image}}' "$running" 2>/dev/null)
fi
if [ -z "$IMAGE" ]; then
    echo "test_log_import_limits: cannot find the MariaDB image; run make up first (or set LOG_LIMITS_IMAGE)" >&2
    exit 2
fi
for f in scripts/rotate_log.sh scripts/mariadb_admin_auth.sh database/migrations/008_import_plugin_log_errors.sql; do
    [ -f "$f" ] || { echo "test_log_import_limits: $f not found" >&2; exit 2; }
done

random_hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cleanup() { docker rm -f -v "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

# The passwords exist only inside this container; they are random and never printed.
if ! MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" \
        -e MARIADB_ROOT_PASSWORD="r$(random_hex)" -e CAMPUS_APP_PASSWORD="a$(random_hex)" \
        "$IMAGE" >/dev/null; then
    echo "test_log_import_limits: could not start the throw-away container" >&2
    exit 2
fi
put() {   # put <source> <destination in the container>; line endings normalised
    tr -d '\r' < "$1" | MSYS_NO_PATHCONV=1 docker exec -i "$NAME" bash -c "mkdir -p \"\$(dirname '$2')\" && cat > '$2'"
}

ready=0
for _ in $(seq 1 180); do
    if MSYS_NO_PATHCONV=1 docker exec "$NAME" bash -c 'MYSQL_PWD=$MARIADB_ROOT_PASSWORD mariadb -uroot -N -e "SELECT COUNT(*) FROM mysql.user WHERE user = '"'"'campus_app'"'"'" 2>/dev/null' 2>/dev/null | tr -d '\r' | grep -qx 1; then
        ready=1; break
    fi
    sleep 1
done
[ "$ready" = 1 ] || { echo "FAIL: the throw-away server did not become ready"; exit 1; }
put scripts/rotate_log.sh /opt/checkout/scripts/rotate_log.sh
put scripts/mariadb_admin_auth.sh /opt/checkout/scripts/mariadb_admin_auth.sh
put database/migrations/008_import_plugin_log_errors.sql /opt/checkout/008.sql

MSYS_NO_PATHCONV=1 docker exec -i "$NAME" bash -s <<'INNER'
set -u
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
q() { printf '%s\n' "$1" | mariadb -uroot --batch --skip-column-names 2>&1; }
ROTATE=/opt/checkout/scripts/rotate_log.sh
rotate() { bash "$ROTATE" "$@" 2>&1; }
DIR=/var/log/campus_audit
LOG=$DIR/campus_audit.jsonl
LIMIT=65536

# Server ready for the final configuration (the entrypoint restarts it once).
for _ in $(seq 1 60); do [ "$(q "SELECT 1;")" = 1 ] && break; sleep 1; done
q "INSTALL SONAME 'campus_audit';" >/dev/null
mariadb -uroot < /opt/checkout/008.sql || { echo "FAIL: migration 008 of this checkout did not apply"; exit 1; }
[ "$(q "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';")" = ACTIVE ] \
    || { echo "FAIL: campus_audit is not ACTIVE"; exit 1; }
ORIG_PACKET=$(q "SELECT @@GLOBAL.max_allowed_packet;")
instance=$(tail -n 1 "$LOG" | sed -n 's/.*"instance":"\([^"]*\)".*/\1/p')
[ -n "$instance" ] || { echo "FAIL: cannot read the plugin instance"; exit 1; }
write_records() {   # write_records <n>: n audited statements that change no row (table_write + statement each)
    local i sqltext=""
    for i in $(seq 1 "$1"); do sqltext="$sqltext UPDATE university_resources.rooms SET capacity = capacity WHERE room_id = 0 AND name = 'import-limit-$i';"; done
    q "$sqltext" >/dev/null
}
rows() { q "SELECT COUNT(*) FROM campus_audit.plugin_events WHERE instance_id = '$instance';"; }
lines_of() { cat "$@" | grep -c "\"instance\":\"$instance\""; }
no_parts() { [ -z "$(find "$DIR" -maxdepth 1 -name '.import-parts.*' -print -quit)" ]; }

# ---------------------------------------------------------------- 1. ordinary rotation
write_records 20
out=$(rotate); status=$?
archive1=$(printf '%s\n' "$out" | sed -n 's/^Rotated: \(.*\.jsonl\) (.*/\1/p')
if [ "$status" -eq 0 ] && [ -n "$archive1" ] && printf '%s' "$out" | grep -q "Imported the archived file" \
   && ! printf '%s' "$out" | grep -q "line-aligned parts"; then
    pass "ordinary rotation (default limit $ORIG_PACKET): renamed, reopened, both files imported in one call each"
else fail "ordinary rotation" "$out"; fi
if [ "$(lines_of "$archive1" "$LOG")" = "$(rows)" ] && no_parts; then
    pass "ordinary rotation: every record of the two files is in plugin_events exactly once ($(rows)); no temporary file"
else fail "ordinary rotation: lines vs rows" "files $(lines_of "$archive1" "$LOG"), rows $(rows)"; fi

# ---------------------------------------------------------------- 2. a log that grew to the limit
q "SET GLOBAL max_allowed_packet = $LIMIT;" >/dev/null
write_records 150
size=$(stat -c %s "$LOG")
if [ "$size" -ge "$LIMIT" ]; then pass "the active log has grown to $size bytes, at or above max_allowed_packet = $LIMIT"
else fail "the active log did not reach the limit" "$size bytes"; fi
out=$(q "CALL campus_audit.import_plugin_log('$LOG');")
if printf '%s' "$out" | grep -q "ERROR 1644" && printf '%s' "$out" | grep -q "not smaller than max_allowed_packet" \
   && printf '%s' "$out" | grep -q "make import-log"; then
    pass "import_plugin_log() refuses it with ER 1644 and names the remedy (import in parts)"
else fail "refusal of the oversized log" "$out"; fi

# ---------------------------------------------------------------- 3. rotation of the oversized log
# Archive names carry the UTC second; a second rotation within the same
# second is refused by design ("exists already; wait a second").
sleep 1.1
out=$(rotate); status=$?
archive2=$(printf '%s\n' "$out" | sed -n 's/^Rotated: \(.*\.jsonl\) (.*/\1/p')
parts=$(printf '%s\n' "$out" | sed -n "s/^Imported '.*' in \([0-9]*\) parts\.$/\1/p" | head -n 1)
if [ "$status" -eq 0 ] && [ -n "$archive2" ] && [ "${parts:-0}" -ge 2 ] && printf '%s' "$out" | grep -q "Imported the new file"; then
    pass "rotate_log.sh rotates the oversized log and imports the archive ($(stat -c %s "$archive2") bytes) in $parts line-aligned parts"
else fail "rotation of the oversized log" "$out"; fi
sum_before=$(sha256sum "$archive2" | cut -d' ' -f1)
if no_parts; then pass "no part file is left after the import"; else fail "part files left" "$(ls -a "$DIR")"; fi
q "CALL campus_audit.import_plugin_log('$LOG');" >/dev/null
if [ "$(lines_of "$archive1" "$archive2" "$LOG")" = "$(rows)" ]; then
    pass "nothing lost, nothing duplicated: $(rows) records in the three files and in plugin_events"
else fail "lines vs rows after the oversized rotation" "files $(lines_of "$archive1" "$archive2" "$LOG"), rows $(rows)"; fi

# ---------------------------------------------------------------- 4. --import (recovery path)
out=$(rotate --import "$archive2"); status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q "invalid, 0 new" && printf '%s' "$out" | grep -q "parts"; then
    pass "rotate_log.sh --import re-imports the oversized archive in parts and adds nothing"
else fail "--import of the oversized archive" "$out"; fi
if [ "$(sha256sum "$archive2" | cut -d' ' -f1)" = "$sum_before" ] && no_parts; then
    pass "the archive is unchanged (same SHA-256) and no part file is left"
else fail "archive changed or parts left"; fi

# ---------------------------------------------------------------- 5. raising the GLOBAL limit
archive2_size=$(stat -c %s "$archive2" 2>/dev/null || echo 0)
bigger=$(( ( archive2_size / 1024 + 2 ) * 1024 ))
q "SET GLOBAL max_allowed_packet = $bigger;" >/dev/null
out=$(q "SELECT @@SESSION.max_allowed_packet; CALL campus_audit.import_plugin_log('$archive2');")
if printf '%s' "$out" | head -n 1 | grep -qx "$bigger" && printf '%s' "$out" | grep -Eq "	[0-9]+	0	0$"; then
    pass "after SET GLOBAL max_allowed_packet = $bigger a new connection imports the archive in one call (0 new)"
else fail "import with the raised GLOBAL limit" "$out"; fi
q "SET GLOBAL max_allowed_packet = $LIMIT;" >/dev/null

# ---------------------------------------------------------------- 6. a single line above the limit
long=$DIR/test-long-line.jsonl
{ printf '{"instance":"long-line-test","seq":1,"pad":"'; head -c 70000 /dev/zero | tr '\0' 'x'; printf '"}\n'; } > "$long"
chmod 0644 "$long"
sum_long=$(sha256sum "$long" | cut -d' ' -f1)
before=$(q "SELECT COUNT(*) FROM campus_audit.plugin_events;")
out=$(rotate --import "$long"); status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "contains a line of" && printf '%s' "$out" | grep -q "Nothing was imported" \
   && printf '%s' "$out" | grep -q "SET GLOBAL max_allowed_packet"; then
    pass "a line at or above the limit is refused before any import, with the remedy (exit 1)"
else fail "file with a too long line" "status $status: $out"; fi
if [ "$(q "SELECT COUNT(*) FROM campus_audit.plugin_events;")" = "$before" ] && [ "$(sha256sum "$long" | cut -d' ' -f1)" = "$sum_long" ] && no_parts; then
    pass "after that refusal nothing was imported, the file is unchanged and no part file is left"
else fail "state after the too-long-line refusal"; fi

# ---------------------------------------------------------------- 7. missing file
out=$(rotate --import "$DIR/does-not-exist.jsonl"); status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "not a regular file"; then pass "a missing file is refused (exit 1)"
else fail "missing file" "status $status: $out"; fi

q "SET GLOBAL max_allowed_packet = $ORIG_PACKET;" >/dev/null
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER
