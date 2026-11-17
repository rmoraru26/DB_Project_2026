#!/usr/bin/env bash
# Experiment 32 (docs/experiments.md): a log destination that stalls instead of
# failing, and the plugin's cost under concurrent writes.
#
#   bash stall_and_contention.sh <server image> [1|2]   (default: both parts)
#
# Runs everything in one throw-away container started from the project's
# server image (docker/mariadb/Dockerfile); random root password, never
# printed; the container and its anonymous volume are removed at the end.
set -u
IMAGE=${1:?usage: $0 <server image> [1|2]}
PARTS=${2:-12}
NAME=campus-audit-exp32-$$
export MSYS_NO_PATHCONV=1
rh() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
trap 'docker rm -f -v "$NAME" >/dev/null 2>&1' EXIT
docker run -d --name "$NAME" -e MARIADB_ROOT_PASSWORD="r$(rh)" -e CAMPUS_APP_PASSWORD="a$(rh)" "$IMAGE" >/dev/null || exit 2

docker exec -i -e PARTS="$PARTS" "$NAME" bash -s <<'INNER'
set -u
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
CLIENT="mariadb -uroot -h127.0.0.1 --protocol=tcp --skip-ssl --batch --skip-column-names"
q() { $CLIENT -e "$1" 2>&1; }
status() { q "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = '$1'"; }
for _ in $(seq 1 180); do
    [ "$(q "SELECT COUNT(*) FROM university_resources.users WHERE email='alice.student@example.edu'")" = 1 ] && break
    sleep 1
done
q "INSTALL SONAME 'campus_audit'" >/dev/null
echo "Server: $(q "SELECT @@version"), campus_audit $(q "SELECT PLUGIN_AUTH_VERSION FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit'"), $(nproc) CPUs visible, max_connections $(q "SELECT @@max_connections")"
q "CREATE DATABASE watched; CREATE TABLE watched.t (id INT AUTO_INCREMENT PRIMARY KEY, c CHAR(40));
   CREATE DATABASE other;   CREATE TABLE other.t   (id INT AUTO_INCREMENT PRIMARY KEY, c CHAR(40));
   SET GLOBAL campus_audit_databases = 'watched'"

# probe <seconds> <sql>: runs the statement in a new connection with a
# client-side time limit.
probe() {
    local start end rc
    start=$(date +%s%N)
    timeout "$1" $CLIENT -e "$2" >/dev/null 2>/tmp/probe.err
    rc=$?
    end=$(date +%s%N)
    case $rc in
        0)   echo "completed in $(( (end - start) / 1000000 )) ms" ;;
        124) echo "no answer within $1 s (client gave up)" ;;
        *)   echo "error: $(tr '\n' ' ' < /tmp/probe.err)" ;;
    esac
}

if [[ $PARTS == *1* ]]; then
echo
echo "== part 1: a log destination that stalls (a FIFO whose reader stops reading)"
FIFO=/var/log/campus_audit/stall.fifo
mkfifo "$FIFO"; chown mysql:mysql "$FIFO"
# A reader that opens the FIFO and never reads: once the kernel pipe buffer
# (64 KiB) is full, every write() of the plugin blocks.  This stands for a
# hung network file system or a stalled pipe: nothing fails, so the
# plugin's fail-open handling of write errors does not apply.
sleep 100000 < "$FIFO" &
READER=$!
q "SET GLOBAL campus_audit_file_path = '$FIFO'"
echo "file_path now $(q "SELECT @@GLOBAL.campus_audit_file_path"), state $(status CAMPUS_AUDIT_STATE)"
# One client sends 1000 recorded INSERTs one after the other, in the background.
for i in $(seq 1 1000); do echo "INSERT INTO watched.t (c) VALUES (REPEAT('x', 40));"; done \
    | $CLIENT >/dev/null 2>&1 &
WRITER=$!
sleep 5
before=$(q "SELECT COUNT(*) FROM watched.t"); sleep 3; after=$(q "SELECT COUNT(*) FROM watched.t")
echo "the writer of 1000 INSERTs: $before rows committed after 5 s, $after rows 3 s later"
echo "probes, each in a new connection:"
echo "  INSERT into the watched table:             $(probe 5 "INSERT INTO watched.t (c) VALUES ('probe')")"
echo "  INSERT into an unwatched schema:           $(probe 5 "INSERT INTO other.t (c) VALUES ('probe')")"
echo "  SELECT from an unwatched schema:           $(probe 5 "SELECT COUNT(*) FROM other.t")"
echo "  SHOW GLOBAL STATUS LIKE 'Uptime':          $(probe 5 "SHOW GLOBAL STATUS LIKE 'Uptime'")"
echo "  SHOW GLOBAL STATUS LIKE 'Campus_audit%':   $(probe 5 "SHOW GLOBAL STATUS LIKE 'Campus_audit%'")"
echo "  SET GLOBAL campus_audit_reopen_now = ON:   $(probe 5 "SET GLOBAL campus_audit_reopen_now = ON")"
echo "  (that SET keeps waiting inside the server, in the variable's update function)"
echo "  SELECT @@GLOBAL.max_connections:           $(probe 5 "SELECT @@GLOBAL.max_connections")"
echo "  SET GLOBAL max_connections = 152:          $(probe 5 "SET GLOBAL max_connections = 152")"
echo "  SHOW GLOBAL VARIABLES LIKE 'version':      $(probe 5 "SHOW GLOBAL VARIABLES LIKE 'version'")"
echo "  SELECT 1 in a new connection:              $(probe 5 "SELECT 1")"
echo "server-side view (PROCESSLIST, statements still running):"
timeout 5 $CLIENT -e "SELECT COUNT(*), STATE, LEFT(INFO, 45) FROM information_schema.PROCESSLIST
    WHERE ID <> CONNECTION_ID() AND COMMAND = 'Query' GROUP BY STATE, LEFT(INFO, 45)" > /tmp/pl.txt 2>&1
case $? in
    0)   sed 's/^/  /' /tmp/pl.txt ;;
    124) echo "  no answer within 5 s" ;;
    *)   sed 's/^/  error: /' /tmp/pl.txt ;;
esac
echo "-- a reader that reads again (draining the FIFO)"
# Opened read-write, so that the reader never sees end-of-file when the
# plugin closes the FIFO to reopen it (campus_audit_reopen_now above).
cat 0<> "$FIFO" > /var/log/campus_audit/drained.jsonl &
DRAIN=$!
start=$(date +%s%N)
recovered=""
for _ in $(seq 1 600); do
    if timeout 2 $CLIENT -e "SELECT 1" >/dev/null 2>&1; then
        recovered=$(( ($(date +%s%N) - start) / 1000000 )); break
    fi
    sleep 0.1
done
echo "a new connection's SELECT 1 answered ${recovered:-never (60 s)} ms after draining began"
for _ in $(seq 1 600); do kill -0 "$WRITER" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$WRITER" 2>/dev/null; then
    echo "the writer had not finished 60 s after draining began"
else
    echo "the writer finished $(( ($(date +%s%N) - start) / 1000000 )) ms after draining began"
fi
sleep 2
echo "rows: watched.t $(q "SELECT COUNT(*) FROM watched.t") (1000 from the writer + 1 probe), other.t $(q "SELECT COUNT(*) FROM other.t") (1 probe)"
echo "state $(status CAMPUS_AUDIT_STATE), events dropped $(status CAMPUS_AUDIT_EVENTS_DROPPED), write failures $(status CAMPUS_AUDIT_WRITE_FAILURES)"
q "SET GLOBAL campus_audit_file_path = '/var/log/campus_audit/campus_audit.jsonl'"
kill "$READER" "$DRAIN" 2>/dev/null
sleep 1
echo "table_write records for watched.t delivered through the FIFO: $(grep -c '"event":"table_write"' /var/log/campus_audit/drained.jsonl)"

fi

if [[ $PARTS == *2* ]]; then
echo
echo "== part 2: cost under concurrent writes (mariadb-slap, autocommit single-row INSERTs)"
echo "modes: off = plugin not installed; filtered = installed, table not watched (campus_audit_databases='other');"
echo "       recorded = installed, every INSERT recorded (two records per statement)."
echo "Five rounds, the three modes interleaved within each round; 20000 INSERTs per run;"
echo "seconds per run (lower is better), then the median."
slap() {   # slap <concurrency>
    mariadb-slap -uroot -h127.0.0.1 --protocol=tcp --skip-ssl --create-schema=watched --no-drop \
        --query="INSERT INTO watched.t (c) VALUES ('slap')" --concurrency="$1" \
        --number-of-queries=20000 --iterations=1 2>/dev/null \
        | awk '/Average number of seconds/ {print $(NF-1)}'
}
set_mode() {
    case $1 in
        off)      q "UNINSTALL SONAME 'campus_audit'" >/dev/null ;;
        filtered) q "INSTALL SONAME 'campus_audit'" >/dev/null; q "SET GLOBAL campus_audit_databases = 'other'" ;;
        recorded) q "INSTALL SONAME 'campus_audit'" >/dev/null; q "SET GLOBAL campus_audit_databases = 'watched'" ;;
    esac
}
median() { tr ' ' '\n' | grep . | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
printf '%-8s %-9s %-36s %s\n' clients mode "rounds 1..5" median
for c in 1 8 32; do
    r_off=""; r_filtered=""; r_recorded=""
    for r in 1 2 3 4 5; do
        for m in off filtered recorded; do
            set_mode "$m"
            q "TRUNCATE watched.t"
            v=$(slap "$c")
            eval "r_$m=\"\$r_$m $v\""
        done
    done
    for m in off filtered recorded; do
        eval "vals=\$r_$m"
        printf '%-8s %-9s %-36s %s\n' "$c" "$m" "$vals" "$(echo "$vals" | median)"
    done
done
set_mode recorded
echo "log size after part 2: $(wc -c < /var/log/campus_audit/campus_audit.jsonl) bytes; events dropped $(status CAMPUS_AUDIT_EVENTS_DROPPED)"
fi
INNER
echo "# exit status: $?"
