#!/usr/bin/env bash
# Final verification, native Windows (Git Bash), modelled on the windows-native
# CI job: build campus_audit.dll and the unit tests with plugin/build_windows.ps1
# (Zig 0.16.0, MariaDB 13.0.2 headers/libs from the official zip, both verified
# against the SHA-256 values of ci.yml in Phase 1), build the CHANGE_USER helper,
# then a throw-away mariadbd (loopback, random root password, never printed):
# INSTALL SONAME, setup_database.sh, demo.sh, the end-to-end harness and the
# database test scripts.  Source: a Windows-style export of tree 28f2fc09.
set -u
SRC=$1; OUT=$2
WN="<scratch-p1>/win-native"
ZIG="$WN/zig/zig-x86_64-windows-0.16.0/zig.exe"
MDB0="$WN/mdb/mariadb-13.0.2-winx64"
WORK="$(dirname "$OUT")/native-work"
MDB="$WORK/mariadb-13.0.2-winx64"     # private copy of the server, so the Phase 1 copy stays as it is
DATA="$WORK/data"; PORT=23398; BUILD="$WORK/build"
mkdir -p "$OUT" "$WORK"
step() { local f=$1; shift; { echo "# $(date -u +%FT%TZ) $*"; "$@"; echo "# exit status: $?"; } > "$OUT/$f.txt" 2>&1; echo "$f: $(tail -n 1 "$OUT/$f.txt")"; }

echo "## toolchain: zig $("$ZIG" version); server zip copy"
[ -d "$MDB" ] || cp -r "$MDB0" "$MDB" || exit 2
sha256sum "$WN/dl-mariadb/"* "$WN/dl-zig/"* 2>/dev/null | sed 's#  .*/#  #' > "$OUT/00-toolchain-sha256.txt"
echo "zig $("$ZIG" version)" >> "$OUT/00-toolchain-sha256.txt"

cd "$SRC" || exit 2
# 1. DLL and the seven unit-test programs, exactly as CI: build_windows.ps1 without -SkipTests
step 01-build-windows-ps1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File plugin/build_windows.ps1 \
    -MariaDBDir "$(cygpath -w "$MDB")" -Zig "$(cygpath -w "$ZIG")" -OutDir "$(cygpath -w "$BUILD")"
# If application control refused a test program, run the DLL-only build so the load test can still run.
if [ ! -s "$BUILD/campus_audit.dll" ]; then
    step 01b-build-dll-only powershell.exe -NoProfile -ExecutionPolicy Bypass -File plugin/build_windows.ps1 \
        -MariaDBDir "$(cygpath -w "$MDB")" -Zig "$(cygpath -w "$ZIG")" -OutDir "$(cygpath -w "$BUILD")" -SkipTests
fi
ls -l "$BUILD"/*.dll "$BUILD"/*.exe 2>/dev/null | awk '{print $5, $NF}' > "$OUT/01c-build-outputs.txt"
# 2. CHANGE_USER helper (ci.yml)
step 02-change-user-helper "$ZIG" cc -target x86_64-windows-gnu -O2 "-I$(cygpath -w "$MDB")\\include\\mysql" tests/plugin/change_user.c \
    "$(cygpath -w "$MDB")\\lib\\libmariadb.lib" -o "$(cygpath -w "$WORK")\\campus_change_user.exe"

# 3. server
cp "$BUILD/campus_audit.dll" "$MDB/lib/plugin/campus_audit.dll" || exit 3
rm -rf "$DATA"
MYSQL_PWD="r$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; export MYSQL_PWD
"$MDB/bin/mariadb-install-db.exe" --datadir="$(cygpath -w "$DATA")" --port=$PORT --password="$MYSQL_PWD" > "$OUT/03-install-db.txt" 2>&1
echo "# exit status: $?" >> "$OUT/03-install-db.txt"; sed -i "s/$MYSQL_PWD/<password>/g" "$OUT/03-install-db.txt"
printf '\n[mysqld]\nplugin_maturity=beta\nbind-address=127.0.0.1\nport=%s\n' "$PORT" >> "$DATA/my.ini"
"$MDB/bin/mariadbd.exe" --defaults-file="$(cygpath -w "$DATA/my.ini")" --console < /dev/null > "$OUT/03-server.out.txt" 2> "$OUT/03-server.log.txt" &
admin=("$MDB/bin/mariadb-admin.exe" -h127.0.0.1 -P$PORT -uroot --skip-ssl-verify-server-cert)
client=("$MDB/bin/mariadb.exe" -h127.0.0.1 -P$PORT -uroot --skip-ssl-verify-server-cert --batch --skip-column-names --force)
stop() { "${admin[@]}" shutdown > /dev/null 2>&1; wait 2>/dev/null; echo "## server stopped"; }
trap stop EXIT
for _ in $(seq 1 40); do "${admin[@]}" ping > /dev/null 2>&1 && break; sleep 1; done
{
    echo "SELECT CONCAT(VERSION(), ' on ', @@version_compile_os);"
    echo "INSTALL SONAME 'campus_audit';"
    echo "SHOW WARNINGS;"
    echo "SELECT CONCAT_WS(' | ', PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY, PLUGIN_AUTH_VERSION, PLUGIN_MATURITY, PLUGIN_LICENSE) FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';"
    echo "SELECT CONCAT('statement_scope: ', @@GLOBAL.campus_audit_statement_scope);"
} | "${client[@]}" > "$OUT/04-install-soname.txt" 2>&1
echo "04-install-soname: $(grep 'campus_audit |' "$OUT/04-install-soname.txt")"

export MARIADB_CLIENT="$MDB/bin/mariadb.exe -h127.0.0.1 -P$PORT --skip-ssl-verify-server-cert"
export PATH="$MDB/lib:$PATH"
export CHANGE_USER_CLIENT="$WORK/campus_change_user.exe" CU_HOST=127.0.0.1 CU_PORT=$PORT
export DB_ADMIN_USER=root
# As in the Docker installation, also create campus_app (random, never printed).
export CAMPUS_APP_PASSWORD="a$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
step 05-setup-database bash scripts/setup_database.sh
step 06-demo bash scripts/demo.sh
step 07-plugin-harness bash tests/plugin/run_plugin_tests.sh
for t in test_legacy_admin_migration test_cancelled_loan_migration test_audit_triggers test_app_account_grants test_demo_student test_catalogue test_log_import test_native_password_hash run_database_tests; do
    step "08-db-$t" bash "tests/database/$t.sh"
done
