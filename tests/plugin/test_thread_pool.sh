#!/usr/bin/env bash
# Statement correlation of campus_audit under MariaDB's thread pool.
#
#   make test-threadpool          (or: bash tests/plugin/test_thread_pool.sh)
#
# Why this test exists.  The plugin keeps per-statement state in two places:
#
#   * per CONNECTION, in hidden session variables (THDVAR): "this statement
#     touched a watched table", and the latch of campus_audit_statement_scope
#     = SESSION (plugin/src/statement_scope.h);
#   * per OS THREAD, in one thread_local flag: "this statement was an accepted
#     SET GLOBAL campus_audit_*", set in the variable's update callback and
#     read by the statement's own GENERAL STATUS event.
#
# With one thread per connection the two are the same thing.  With
# thread_handling=pool-of-threads a few worker threads serve many connections,
# so a connection's statements run on changing threads.  The thread_local flag
# is then correct only if a statement stays on one thread from its update
# callback to its STATUS event, and the THDVARs only if they travel with the
# connection.  The audit API header promises neither in words; this test
# measures both on the server version the project targets.  It is an
# observation for 13.0.2, repeated on every run, not an API guarantee.
#
# What it does: starts a second, throw-away MariaDB container from the image
# of the running stack with --thread-handling=pool-of-threads and a pool of
# THREAD_POOL_SIZE (default 2) threads, and lets CLIENTS (12) connections each
# run ITERATIONS (30) rounds, in two phases:
#
#   phase 1, scope TABLES (the default)
#     SET GLOBAL campus_audit_max_sql_length = <unique value>;   config change -> thread_local flag
#     SELECT SLEEP(0.01);                                        gives the pool a reason to switch
#     INSERT INTO university_resources.audit_lab_notes ...;      watched table + trigger -> THDVAR
#     SELECT <i>;                                                must never be recorded
#
#   phase 2, scope SESSION
#     LOCK TABLES university_resources.pool_lock WRITE;          table event, sets the latch
#     INSERT INTO university_resources.pool_lock ...;            no table event: recorded by the latch
#     UNLOCK TABLES;                                             recorded by the latch
#     SELECT SLEEP(0.01);                                        recorded by the latch
#     INSERT INTO pool_other.t ...;                              another schema: clears the latch
#     SELECT <i>;                                                must NOT be recorded any more
#
# and then counts the records.  Every count must be exact; one record that is
# attributed to the wrong statement or connection changes at least one count.
#
# The container has no published port and its own anonymous volume; both are
# removed at the end.  The running stack is not touched.  Needs Docker and the
# built image (make up).  Exit status 0 when every check passed.
set -u
cd "$(dirname "$0")/../.."
COMPOSE=(${COMPOSE:-docker compose})
CLIENTS=${CLIENTS:-12}
ITERATIONS=${ITERATIONS:-30}
POOL=${THREAD_POOL_SIZE:-2}
NAME="campus-audit-threadpool-$$-$RANDOM"

IMAGE=${THREAD_POOL_IMAGE:-}
if [ -z "$IMAGE" ]; then
    running=$("${COMPOSE[@]}" ps -q mariadb 2>/dev/null | head -n 1)
    [ -n "$running" ] && IMAGE=$(docker inspect --format '{{.Image}}' "$running" 2>/dev/null)
fi
if [ -z "$IMAGE" ]; then
    echo "test_thread_pool: cannot find the MariaDB image; run make up first (or set THREAD_POOL_IMAGE)" >&2
    exit 2
fi

random_hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cleanup() { docker rm -f -v "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

# The passwords exist only inside this container; they are random and never printed.
if ! MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" \
        -e MARIADB_ROOT_PASSWORD="r$(random_hex)" -e CAMPUS_APP_PASSWORD="a$(random_hex)" \
        "$IMAGE" --thread-handling=pool-of-threads --thread-pool-size="$POOL" >/dev/null; then
    echo "test_thread_pool: could not start the throw-away container" >&2
    exit 2
fi

MSYS_NO_PATHCONV=1 docker exec -i -e CLIENTS="$CLIENTS" -e ITERATIONS="$ITERATIONS" -e POOL="$POOL" "$NAME" bash -s <<'INNER'
set -u
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
expect() {   # expect "<description>" <actual> <expected>
    if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: expected $3, got $2"; fi
}
q() { mariadb -uroot --batch --skip-column-names -e "$1" 2>&1; }
status_of() { q "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = '$1'"; }

# The image initialises its database on first start; wait for the final server.
ready=0
for _ in $(seq 1 180); do
    if [ "$(q "SELECT COUNT(*) FROM mysql.user WHERE user = 'campus_app'")" = 1 ] \
       && [ "$(q "SELECT COUNT(*) FROM university_resources.users WHERE email = 'alice.student@example.edu'")" = 1 ]; then
        ready=1; break
    fi
    sleep 1
done
[ "$ready" = 1 ] || { echo "FAIL: the throw-away server did not become ready"; exit 1; }

q "INSTALL SONAME 'campus_audit';" >/dev/null
echo "Server: $(q "SELECT CONCAT(@@version, ', thread_handling=', @@thread_handling, ', thread_pool_size=', @@thread_pool_size)"), campus_audit $(q "SELECT PLUGIN_AUTH_VERSION FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit'")"
expect "thread_handling" "$(q "SELECT @@thread_handling")" "pool-of-threads"
expect "thread_pool_size" "$(q "SELECT @@thread_pool_size")" "$POOL"
expect "campus_audit plugin" "$(q "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit'")" "ACTIVE"
expect "statement scope at the start" "$(q "SELECT @@GLOBAL.campus_audit_statement_scope")" "TABLES"
q "CREATE TABLE university_resources.pool_lock (c INT, i INT, PRIMARY KEY (c, i)) ENGINE=InnoDB;
   CREATE DATABASE pool_other; CREATE TABLE pool_other.t (c INT, i INT, PRIMARY KEY (c, i)) ENGINE=InnoDB;" >/dev/null

LOG=$(q "SELECT @@GLOBAL.campus_audit_file_path")
total=$((CLIENTS * ITERATIONS))
run_clients() {   # run_clients <phase>: every client in its own connection, all at once
    local phase=$1 n start
    start=$(date +%s)
    for n in $(seq 1 "$CLIENTS"); do
        "statements_$phase" "$n" | mariadb -uroot --batch --skip-column-names > /dev/null 2> "/tmp/client-$phase-$n.err" &
    done
    wait
    echo "Phase $phase: $CLIENTS connections x $ITERATIONS rounds in $(( $(date +%s) - start )) s; pool worker threads now: $(status_of THREADPOOL_THREADS)"
    expect "phase $phase: client errors" "$(cat /tmp/client-"$phase"-*.err 2>/dev/null | wc -l | tr -d ' ')" 0
}
statements_1() {
    local n=$1 i
    for i in $(seq 1 "$ITERATIONS"); do
        echo "SET GLOBAL campus_audit_max_sql_length = $((1000 + n * 100 + i));"
        echo "SELECT SLEEP(0.01);"
        echo "INSERT INTO university_resources.audit_lab_notes (owner_user_id, label, quantity) SELECT user_id, 'pool-$n-$i', 1 + $i % 100 FROM university_resources.users WHERE email = 'alice.student@example.edu';"
        echo "SELECT $i;"
    done
}
statements_2() {
    local n=$1 i
    for i in $(seq 1 "$ITERATIONS"); do
        echo "LOCK TABLES university_resources.pool_lock WRITE;"
        echo "INSERT INTO university_resources.pool_lock VALUES ($n, $i);"
        echo "UNLOCK TABLES;"
        echo "SELECT SLEEP(0.01);"
        echo "INSERT INTO pool_other.t VALUES ($n, $i);"
        echo "SELECT $i;"
    done
}
statements() { grep '"event":"statement"' /tmp/phase.jsonl; }
per_connection() {   # per_connection <grep pattern>: connections with exactly ITERATIONS matching statement records
    statements | grep "$1" | grep -o '"conn":[0-9]*' | sort | uniq -c | awk -v m="$ITERATIONS" '$1 == m' | wc -l | tr -d ' '
}

# ------------------------------------------------------------------ phase 1: scope TABLES
before=$(wc -l < "$LOG")
run_clients 1
tail -n +$((before + 1)) "$LOG" > /tmp/phase.jsonl
expect "phase 1: rows inserted into the watched table" "$(q "SELECT COUNT(*) FROM university_resources.audit_lab_notes WHERE label LIKE 'pool-%'")" "$total"
expect "phase 1: records written" "$(wc -l < /tmp/phase.jsonl | tr -d ' ')" "$((total * 5))"
# thread_local flag: every SET GLOBAL is attributed, and only SET GLOBAL
expect "phase 1: config_change records" "$(grep -c '"event":"config_change"' /tmp/phase.jsonl)" "$total"
expect "phase 1: statement records for the SET GLOBAL statements" \
       "$(statements | grep -c '"sql_digest":"SET GLOBAL campus_audit_max_sql_length = ?"')" "$total"
expect "phase 1: connections with exactly $ITERATIONS SET GLOBAL statement records" \
       "$(per_connection '"sql_digest":"SET GLOBAL campus_audit_max_sql_length')" "$CLIENTS"
expect "phase 1: stray records for SELECT (another statement's flag or id leaked to it)" \
       "$(statements | grep -c '"sql_digest":"SELECT')" 0
# THDVAR: the INSERT's statement record and its two table events (table and trigger) share conn and query_id
expect "phase 1: statement records for the INSERT" \
       "$(statements | grep -c '"sql_digest":"INSERT INTO university_resources.audit_lab_notes')" "$total"
statements | grep '"sql_digest":"INSERT INTO university_resources.audit_lab_notes' | grep -o '"conn":[0-9]*,"query_id":[0-9]*' | sort > /tmp/stmt.keys
grep '"event":"table_write"' /tmp/phase.jsonl | grep -o '"conn":[0-9]*,"query_id":[0-9]*' | sort | uniq -c | awk '$1 == 2 { print $2 }' | sort > /tmp/write.keys
expect "phase 1: INSERT statements whose (conn, query_id) has exactly two table_write records" \
       "$(comm -12 /tmp/stmt.keys /tmp/write.keys | wc -l | tr -d ' ')" "$total"
expect "phase 1: records marked scope=session (the default scope records none)" "$(grep -c '"scope":"session"' /tmp/phase.jsonl)" 0

# ------------------------------------------------------------------ phase 2: scope SESSION
q "SET GLOBAL campus_audit_statement_scope = 'SESSION';" >/dev/null
before=$(wc -l < "$LOG")
run_clients 2
tail -n +$((before + 1)) "$LOG" > /tmp/phase.jsonl
q "SET GLOBAL campus_audit_statement_scope = 'TABLES';" >/dev/null
expect "phase 2: rows inserted under LOCK TABLES" "$(q "SELECT COUNT(*) FROM university_resources.pool_lock")" "$total"
expect "phase 2: rows inserted into the other schema" "$(q "SELECT COUNT(*) FROM pool_other.t")" "$total"
expect "phase 2: LOCK TABLES statements, each with its one table event" \
       "$(statements | grep -c '"sql_digest":"LOCK TABLES university_resources.pool_lock WRITE"'),$(grep '"event":"table_write"' /tmp/phase.jsonl | grep -c '"table":"pool_lock"')" "$total,$total"
expect "phase 2: INSERTs under LOCK TABLES recorded as scope=session" \
       "$(statements | grep '"scope":"session"' | grep -c '"sql_digest":"INSERT INTO university_resources.pool_lock VALUES (?, ?)"')" "$total"
expect "phase 2: UNLOCK TABLES recorded as scope=session" \
       "$(statements | grep '"scope":"session"' | grep -c '"sql_digest":"UNLOCK TABLES"')" "$total"
expect "phase 2: the table-less statement after UNLOCK TABLES (latch still set) recorded as scope=session" \
       "$(statements | grep '"scope":"session"' | grep -c '"sql_digest":"SELECT SLEEP(?)"')" "$total"
expect "phase 2: connections with exactly $ITERATIONS scope=session INSERT records" \
       "$(per_connection '"scope":"session".*"sql_digest":"INSERT INTO university_resources.pool_lock')" "$CLIENTS"
expect "phase 2: statements on the other schema recorded" "$(grep -c 'pool_other' /tmp/phase.jsonl)" 0
expect "phase 2: SELECT after the latch was cleared recorded (the latch leaked to or from another connection)" \
       "$(statements | grep -c '"sql_digest":"SELECT ?"')" 0
expect "phase 2: records written" "$(wc -l < /tmp/phase.jsonl | tr -d ' ')" "$((total * 5))"

# ------------------------------------------------------------------ the file and the plugin
expect "events dropped" "$(status_of CAMPUS_AUDIT_EVENTS_DROPPED)" 0
expect "write failures" "$(status_of CAMPUS_AUDIT_WRITE_FAILURES)" 0
expect "unexpected events" "$(status_of CAMPUS_AUDIT_EVENTS_UNEXPECTED)" 0
expect "duplicate seq values in the log" "$(grep -o '"seq":[0-9]*' "$LOG" | sort | uniq -d | wc -l | tr -d ' ')" 0
expect "lines that are not one JSON object" "$(grep -vc '^{.*}$' "$LOG")" 0

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER
status=$?
exit "$status"
