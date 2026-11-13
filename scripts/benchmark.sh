#!/usr/bin/env bash
# Overhead benchmark: what does auditing cost on a write-heavy workload?
#
# Workload: ROWS single-row autocommit INSERTs sent through ONE client session
# into a scratch table, measured as client wall-clock time.  (The client
# start-up, and with Docker the `exec` overhead, is inside every measurement
# and is the same for every configuration.)  Configurations:
#
#   none           campus_audit uninstalled, no other audit plugin
#   campus_audit   installed, watching only the scratch schema (campus_bench)
#   server_audit   MariaDB's bundled plugin, events QUERY_DML,TABLE (skipped
#                  with a message if it cannot be installed)
#
# The whole experiment runs PASSES times (default 2), in opposite
# configuration order on every second pass, and each pass reports its own
# numbers: two runs on the same machine are shown side by side, not averaged.
# Each configuration gets one unrecorded warm-up run, then REPS timed runs.
#
# ADMINISTRATOR ACCESS ON A DISPOSABLE SERVER: the script INSTALLs and UNINSTALLs
# plugins, sets innodb_flush_log_at_trx_commit=2 (as in docs/experiments.md) and
# creates/drops the schema campus_bench.  It restores what it changed when it
# exits, but never point it at a production server.
#
#   Docker:  make bench
#   Native:  MYSQL_PWD=... MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" bash scripts/benchmark.sh
#
# Environment: BENCH_ROWS (2000)  BENCH_REPS (5)  BENCH_PASSES (2)
#              BENCH_OUT (bench-results.csv: pass,config,repetition,elapsed_ms)
# Needs bash, awk, sed, seq and `date +%s%N` (Linux, Git Bash on Windows).
#
# STATUS: run natively against MariaDB 13.0.2 on 2026-11-03 (unchanged, default
# parameters): docs/evidence/windows-2026-11-03/11-benchmark.txt and .csv.
# Not yet run through Docker (make bench).

set -eu
set -o pipefail
cd "$(dirname "$0")/.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
ROWS=${BENCH_ROWS:-2000}
REPS=${BENCH_REPS:-5}
PASSES=${BENCH_PASSES:-2}
OUT=${BENCH_OUT:-bench-results.csv}
CONFIGS=(none campus_audit server_audit)

sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }

# ---------------------------------------------------------------- state to restore
ORIG_CAMPUS=$(sql "SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';")
ORIG_FLUSH=$(sql "SELECT @@GLOBAL.innodb_flush_log_at_trx_commit;")

cleanup() {
    set +e
    sql "SET GLOBAL server_audit_logging = OFF;" >/dev/null 2>&1
    sql "UNINSTALL SONAME 'server_audit';" >/dev/null 2>&1
    sql "UNINSTALL SONAME 'campus_audit';" >/dev/null 2>&1
    if [ "$ORIG_CAMPUS" = "1" ]; then sql "INSTALL SONAME 'campus_audit';" >/dev/null 2>&1; fi
    sql "SET GLOBAL innodb_flush_log_at_trx_commit = $ORIG_FLUSH; DROP DATABASE IF EXISTS campus_bench;" >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers
run_workload() {   # prints the elapsed milliseconds
    local t0 t1
    sql "TRUNCATE TABLE campus_bench.t;" >/dev/null
    t0=$(date +%s%N)
    seq 1 "$ROWS" | sed "s/.*/INSERT INTO campus_bench.t (v) VALUES ('row&');/" \
        | "${CLIENT[@]}" -u"$ADMIN_USER" --batch >/dev/null
    t1=$(date +%s%N)
    echo $(( (t1 - t0) / 1000000 ))
}

setup_config() {   # returns 1 if the configuration is not available
    sql "SET GLOBAL server_audit_logging = OFF;" >/dev/null 2>&1 || true
    sql "UNINSTALL SONAME 'server_audit';" >/dev/null 2>&1 || true
    sql "UNINSTALL SONAME 'campus_audit';" >/dev/null 2>&1 || true
    case "$1" in
        none) ;;
        campus_audit)
            sql "INSTALL SONAME 'campus_audit';" >/dev/null
            sql "SET GLOBAL campus_audit_databases = 'campus_bench';
                 SET GLOBAL campus_audit_file_path = 'campus_audit_bench.jsonl';" >/dev/null ;;
        server_audit)
            sql "INSTALL SONAME 'server_audit';" >/dev/null 2>&1 || return 1
            sql "SET GLOBAL server_audit_events = 'QUERY_DML,TABLE';
                 SET GLOBAL server_audit_file_path = 'campus_bench_server_audit.log';
                 SET GLOBAL server_audit_logging = ON;" >/dev/null 2>&1 || return 1 ;;
    esac
}

median_of() {      # median_of <pass> <config>
    awk -F, -v p="$1" -v c="$2" '$1==p && $2==c {print $4}' "$OUT" | sort -n \
        | awk '{a[NR]=$1} END {if (NR==0) print "NA"; else if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}'
}
range_of() {       # range_of <pass> <config>  -> "min-max"
    awk -F, -v p="$1" -v c="$2" '$1==p && $2==c {print $4}' "$OUT" | sort -n \
        | awk '{a[NR]=$1} END {if (NR==0) print "NA"; else print a[1] "-" a[NR]}'
}

# ---------------------------------------------------------------- run
echo "== $(sql 'SELECT VERSION();') on $(sql 'SELECT @@version_compile_os;'), $(date -u +%FT%TZ)"
echo "== $ROWS INSERTs per run, $REPS timed runs per configuration, $PASSES passes -> $OUT"

sql "DROP DATABASE IF EXISTS campus_bench;
     CREATE DATABASE campus_bench;
     CREATE TABLE campus_bench.t (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(40) NOT NULL) ENGINE=InnoDB;
     SET GLOBAL innodb_flush_log_at_trx_commit = 2;" >/dev/null
echo "pass,config,repetition,elapsed_ms" > "$OUT"

SKIPPED=""
campus_bytes=""
for pass in $(seq 1 "$PASSES"); do
    if [ $((pass % 2)) -eq 1 ]; then order=("${CONFIGS[@]}"); else order=(server_audit campus_audit none); fi
    for config in "${order[@]}"; do
        if ! setup_config "$config"; then
            echo "pass $pass  $config: not available on this server, skipped"
            case " $SKIPPED " in *" $config "*) ;; *) SKIPPED="$SKIPPED $config" ;; esac
            continue
        fi
        run_workload >/dev/null                      # warm-up, not recorded
        before=""
        if [ "$config" = "campus_audit" ]; then
            before=$(sql "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_BYTES_WRITTEN';")
        fi
        for rep in $(seq 1 "$REPS"); do
            ms=$(run_workload)
            echo "$pass,$config,$rep,$ms" >> "$OUT"
            echo "pass $pass  $config  run $rep: $ms ms"
        done
        if [ "$config" = "campus_audit" ]; then
            after=$(sql "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='CAMPUS_AUDIT_BYTES_WRITTEN';")
            campus_bytes="$campus_bytes pass$pass=$(( (after - before) / REPS ))"
        fi
    done
done

# ---------------------------------------------------------------- summary
echo
echo "Median of $REPS runs in ms (min-max); overhead relative to 'none' of the same pass"
printf '%-14s' "config"
for pass in $(seq 1 "$PASSES"); do printf '%-34s' "pass $pass"; done
echo
for config in "${CONFIGS[@]}"; do
    printf '%-14s' "$config"
    for pass in $(seq 1 "$PASSES"); do
        m=$(median_of "$pass" "$config"); r=$(range_of "$pass" "$config"); base=$(median_of "$pass" none)
        if [ "$m" = "NA" ]; then
            cell="skipped"
        elif [ "$config" = "none" ] || [ "$base" = "NA" ] || [ "$base" -eq 0 ]; then
            cell="$m ($r)"
        else
            cell="$m ($r)  $(awk -v m="$m" -v b="$base" 'BEGIN {printf "%+.1f%%", (m - b) * 100 / b}')"
        fi
        printf '%-34s' "$cell"
    done
    echo
done
[ -n "$campus_bytes" ] && echo "campus_audit log volume per run of $ROWS INSERTs (bytes):$campus_bytes"
[ -n "$SKIPPED" ] && echo "skipped configurations:$SKIPPED"
echo "raw timings: $OUT"
