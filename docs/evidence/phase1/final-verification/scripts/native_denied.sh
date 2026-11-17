#!/usr/bin/env bash
# Second native harness run, on a second throw-away server built from the same
# server copy and DLL as native.sh, with AUDIT_TEST_DENIED_PATH pointing into C:\Windows\System32,
# which this non-elevated account cannot write; so the permission-denied block
# runs instead of being skipped.  A fresh data directory (data2) and a new
# random root password (never printed); the plugin is installed and the
# database set up again before the harness.
set -u
SRC=$1; OUT=$2
WORK="$(dirname "$OUT")/native-work"
MDB="$WORK/mariadb-13.0.2-winx64"; DATA="$WORK/data2"; PORT=23397
cd "$SRC" || exit 2
rm -rf "$DATA"
MYSQL_PWD="r$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; export MYSQL_PWD
"$MDB/bin/mariadb-install-db.exe" --datadir="$(cygpath -w "$DATA")" --port=$PORT --password="$MYSQL_PWD" > /dev/null 2>&1 || exit 3
printf '\n[mysqld]\nplugin_maturity=beta\nbind-address=127.0.0.1\nport=%s\n' "$PORT" >> "$DATA/my.ini"
"$MDB/bin/mariadbd.exe" --defaults-file="$(cygpath -w "$DATA/my.ini")" --console < /dev/null > "$OUT/10-server.out.txt" 2> "$OUT/10-server.log.txt" &
admin=("$MDB/bin/mariadb-admin.exe" -h127.0.0.1 -P$PORT -uroot --skip-ssl-verify-server-cert)
trap '"${admin[@]}" shutdown > /dev/null 2>&1; wait 2>/dev/null' EXIT
for _ in $(seq 1 40); do "${admin[@]}" ping > /dev/null 2>&1 && break; sleep 1; done
export MARIADB_CLIENT="$MDB/bin/mariadb.exe -h127.0.0.1 -P$PORT --skip-ssl-verify-server-cert"
export PATH="$MDB/lib:$PATH" DB_ADMIN_USER=root
export CHANGE_USER_CLIENT="$WORK/campus_change_user.exe" CU_HOST=127.0.0.1 CU_PORT=$PORT
export AUDIT_TEST_DENIED_PATH='C:/Windows/System32/campus_audit_denied/campus_audit.jsonl'
export CAMPUS_APP_PASSWORD="a$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
echo "INSTALL SONAME 'campus_audit';" | $MARIADB_CLIENT -uroot > /dev/null 2>&1
{ echo "# $(date -u +%FT%TZ) setup_database.sh, then the harness with AUDIT_TEST_DENIED_PATH=$AUDIT_TEST_DENIED_PATH (not writable for this non-elevated account)";
  bash scripts/setup_database.sh > /dev/null 2>&1; echo "# setup exit status: $?"
  bash tests/plugin/run_plugin_tests.sh; echo "# exit status: $?"; } > "$OUT/10-plugin-harness-denied-path.txt" 2>&1
grep -E "^(SKIP|FAIL|== )|permission|# exit" "$OUT/10-plugin-harness-denied-path.txt"
