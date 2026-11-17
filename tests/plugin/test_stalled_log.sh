#!/usr/bin/env bash
# A log destination that stalls instead of failing (docs/experiments.md, experiment 32).
#
#   make test-stalled-log          (or: bash tests/plugin/test_stalled_log.sh)
#
# Why this test exists.  The plugin writes each record with one write() while
# holding its log mutex.  When the destination stops accepting data without
# failing (a hung network file system, a full pipe), that write() blocks, and
# so does every recorded statement after it: the audit API has no way to
# hand a record over without waiting.  What must NOT happen is that the
# blockage spreads to the rest of the server.  It did in plugin 1.2.0: a
# SET GLOBAL campus_audit_* waited for the mutex inside its update function,
# i.e. while holding LOCK_global_system_variables, and from then on new
# logins, SELECT @@GLOBAL..., SET GLOBAL and SHOW VARIABLES all waited too.
# The update functions and the status functions now wait at most 2 s and
# 0.2 s and then give up with a warning.
#
# What it does: starts a throw-away MariaDB container from the image of the
# running stack (or THREAD_POOL_IMAGE / STALL_TEST_IMAGE), points
# campus_audit_file_path at a FIFO whose reader never reads, lets one client
# send 1000 recorded INSERTs, checks what still answers, then drains the FIFO
# and checks that nothing was lost.  Linux containers only (mkfifo).
#
# The container has no published port and its own anonymous volume; both are
# removed at the end.  The running stack is not touched.  Exit status 0 when
# every check passed.
set -u
cd "$(dirname "$0")/../.."
COMPOSE=(${COMPOSE:-docker compose})
NAME="campus-audit-stall-$$-$RANDOM"

IMAGE=${STALL_TEST_IMAGE:-${THREAD_POOL_IMAGE:-}}
if [ -z "$IMAGE" ]; then
    running=$("${COMPOSE[@]}" ps -q mariadb 2>/dev/null | head -n 1)
    [ -n "$running" ] && IMAGE=$(docker inspect --format '{{.Image}}' "$running" 2>/dev/null)
fi
if [ -z "$IMAGE" ]; then
    echo "test_stalled_log: cannot find the MariaDB image; run make up first (or set STALL_TEST_IMAGE)" >&2
    exit 2
fi

random_hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cleanup() { docker rm -f -v "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

# The passwords exist only inside this container; they are random and never printed.
if ! MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" \
        -e MARIADB_ROOT_PASSWORD="r$(random_hex)" -e CAMPUS_APP_PASSWORD="a$(random_hex)" \
        "$IMAGE" >/dev/null; then
    echo "test_stalled_log: could not start the throw-away container" >&2
    exit 2
fi

MSYS_NO_PATHCONV=1 docker exec -i "$NAME" bash -s <<'INNER'
set -u
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
CLIENT="mariadb -uroot -h127.0.0.1 --protocol=tcp --skip-ssl --batch --skip-column-names"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
q() { timeout 30 $CLIENT -e "$1" 2>&1; }   # never hang the test itself
status_of() { q "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = '$1'"; }

# answers <description> <seconds> <sql> [<text the output must contain>]
# The statement runs in a new connection with SHOW WARNINGS after it.
answers() {
    local out rc
    out=$(timeout "$2" $CLIENT -e "$3; SHOW WARNINGS" 2>&1)
    rc=$?
    if [ "$rc" = 124 ]; then
        fail "$1: no answer within $2 s"
    elif [ "$rc" != 0 ]; then
        fail "$1: $(echo "$out" | tr '\n' ' ')"
    elif [ -n "${4:-}" ] && ! printf '%s' "$out" | grep -q -- "$4"; then
        fail "$1: answered without '$4': $(echo "$out" | tr '\n' ' ')"
    else
        pass "$1"
    fi
}

ready=0
for _ in $(seq 1 180); do
    if [ "$(q "SELECT COUNT(*) FROM university_resources.users WHERE email = 'alice.student@example.edu'")" = 1 ]; then
        ready=1; break
    fi
    sleep 1
done
[ "$ready" = 1 ] || { echo "FAIL: the throw-away server did not become ready"; exit 1; }
q "INSTALL SONAME 'campus_audit';" >/dev/null
echo "Server: $(q "SELECT @@version"), campus_audit $(q "SELECT PLUGIN_AUTH_VERSION FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit'")"
q "CREATE DATABASE watched; CREATE TABLE watched.t (id INT AUTO_INCREMENT PRIMARY KEY, c CHAR(40));
   CREATE DATABASE other;   CREATE TABLE other.t   (id INT AUTO_INCREMENT PRIMARY KEY, c CHAR(40));
   SET GLOBAL campus_audit_databases = 'watched'" >/dev/null

FIFO=/var/log/campus_audit/stall.fifo
mkfifo "$FIFO"; chown mysql:mysql "$FIFO"
sleep 1000000 < "$FIFO" &           # opens the FIFO and never reads
READER=$!
q "SET GLOBAL campus_audit_file_path = '$FIFO'" >/dev/null
[ "$(q "SELECT @@GLOBAL.campus_audit_file_path")" = "$FIFO" ] && pass "log switched to the FIFO" \
    || fail "log not switched to the FIFO"

for i in $(seq 1 1000); do echo "INSERT INTO watched.t (c) VALUES ('w');"; done | $CLIENT >/dev/null 2>&1 &
WRITER=$!
sleep 5
a=$(q "SELECT COUNT(*) FROM watched.t"); sleep 2; b=$(q "SELECT COUNT(*) FROM watched.t")
if [ "$a" = "$b" ] && [ "$a" -lt 1000 ]; then
    pass "recorded statements wait for the stalled log (stopped at $a of 1000 rows)"
else
    fail "the writer was expected to stall: $a then $b rows"
fi

echo "-- with the log stalled, the rest of the server must keep answering"
answers "INSERT into an unwatched schema"                  5 "INSERT INTO other.t (c) VALUES ('o')"
answers "SHOW STATUS of the plugin answers BUSY"           5 "SHOW GLOBAL STATUS LIKE 'Campus_audit_state'" "BUSY"
answers "SET GLOBAL campus_audit_reopen_now gives up"      8 "SET GLOBAL campus_audit_reopen_now = ON" "busy"
answers "SET GLOBAL campus_audit_log_reads: record dropped" 8 "SET GLOBAL campus_audit_log_reads = ON" "busy"
answers "SET GLOBAL campus_audit_file_path gives up"       8 "SET GLOBAL campus_audit_file_path = 'other.jsonl'" "busy"
[ "$(q "SELECT @@GLOBAL.campus_audit_file_path")" = "$FIFO" ] && pass "file_path unchanged after giving up" \
    || fail "file_path changed although the log was busy"
answers "SELECT @@GLOBAL.max_connections"                  5 "SELECT @@GLOBAL.max_connections"
answers "SET GLOBAL max_connections"                       5 "SET GLOBAL max_connections = 152"
answers "SHOW GLOBAL VARIABLES"                            5 "SHOW GLOBAL VARIABLES LIKE 'version'"
answers "a new connection"                                 5 "SELECT 1"

echo "-- draining the FIFO"
cat 0<> "$FIFO" > /var/log/campus_audit/drained.jsonl &
DRAIN=$!
for _ in $(seq 1 600); do kill -0 "$WRITER" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$WRITER" 2>/dev/null; then fail "the writer did not finish within 60 s of draining"
else pass "the writer finished after draining"; fi
sleep 1
[ "$(q "SELECT COUNT(*) FROM watched.t")" = 1000 ] && pass "all 1000 INSERTs committed" \
    || fail "rows committed: $(q "SELECT COUNT(*) FROM watched.t")"
n=$(grep -c '"event":"table_write"' /var/log/campus_audit/drained.jsonl)
[ "$n" = 1000 ] && pass "1000 table_write records delivered through the FIFO" || fail "table_write records: $n"
[ "$(status_of CAMPUS_AUDIT_STATE)" = ACTIVE ] && pass "state ACTIVE after draining" \
    || fail "state $(status_of CAMPUS_AUDIT_STATE)"
[ "$(status_of CAMPUS_AUDIT_EVENTS_DROPPED)" = 1 ] && pass "exactly one record dropped (the config_change of log_reads)" \
    || fail "events dropped: $(status_of CAMPUS_AUDIT_EVENTS_DROPPED)"
q "SET GLOBAL campus_audit_file_path = 'campus_audit.jsonl'" >/dev/null
kill "$READER" "$DRAIN" 2>/dev/null

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
INNER
