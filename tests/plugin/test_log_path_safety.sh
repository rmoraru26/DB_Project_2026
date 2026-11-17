#!/usr/bin/env bash
# Which files SET GLOBAL campus_audit_file_path may open (plugin 1.2.4).
#
#   make test-log-path-safety          (or: bash tests/plugin/test_log_path_safety.sh)
#
# Why this test exists.  campus_audit_file_path needs SYSTEM_VARIABLES_ADMIN,
# not FILE.  Up to 1.2.3 the plugin appended to whatever existing file the
# path named and, with campus_audit_readable_by_all (on in the Docker image),
# made it readable by every OS user.  Since 1.2.4 the checks are made on the
# file actually opened (plugin/src/log_sink.cpp): no symbolic link, no hard
# link, no file of another OS user, no regular file whose name does not end
# in .jsonl, an existing file only if empty or a campus_audit log, and
# permissions widened only on a file the plugin has just created.
#
# What it does: starts a throw-away MariaDB container from the image of the
# running stack (or STALL_TEST_IMAGE / THREAD_POOL_IMAGE), creates DISPOSABLE
# decoy files in the container's own log directory, tries to make the plugin
# open them, and checks that every decoy is byte-for-byte and mode-for-mode
# unchanged.  No MariaDB system file and no user data is ever named.  Then it
# checks that rotation, recovery after a write failure and a server restart
# still work.  Linux containers only.
#
# The container has no published port and its own anonymous volume; both are
# removed at the end.  The running stack is not touched.  Exit status 0 when
# every check passed.
set -u
cd "$(dirname "$0")/../.."
COMPOSE=(${COMPOSE:-docker compose})
NAME="campus-audit-pathsafety-$$-$RANDOM"

IMAGE=${STALL_TEST_IMAGE:-${THREAD_POOL_IMAGE:-}}
if [ -z "$IMAGE" ]; then
    running=$("${COMPOSE[@]}" ps -q mariadb 2>/dev/null | head -n 1)
    [ -n "$running" ] && IMAGE=$(docker inspect --format '{{.Image}}' "$running" 2>/dev/null)
fi
if [ -z "$IMAGE" ]; then
    echo "test_log_path_safety: cannot find the MariaDB image; run make up first (or set STALL_TEST_IMAGE)" >&2
    exit 2
fi

random_hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cleanup() { docker rm -f -v "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

# The passwords exist only inside this container; they are random and never printed.
if ! MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" \
        -e MARIADB_ROOT_PASSWORD="r$(random_hex)" -e CAMPUS_APP_PASSWORD="a$(random_hex)" \
        "$IMAGE" >/dev/null; then
    echo "test_log_path_safety: could not start the throw-away container" >&2
    exit 2
fi

# Shared shell functions for both phases (inside the container).
read -r -d '' COMMON <<'COMMON_END'
set -u
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
CLIENT="mariadb -uroot -h127.0.0.1 --protocol=tcp --skip-ssl --batch --skip-column-names"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
q() { timeout 30 $CLIENT -e "$1" 2>&1; }
status_of() { q "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = '$1'"; }
wait_ready() {
    for _ in $(seq 1 180); do
        [ "$(q "SELECT COUNT(*) FROM university_resources.users WHERE email = 'alice.student@example.edu'")" = 1 ] && return 0
        sleep 1
    done
    return 1
}
D=/var/log/campus_audit
fingerprint() { stat -c '%a %u %h %s' "$1" 2>/dev/null; sha256sum "$1" 2>/dev/null | cut -c1-16; }
COMMON_END

MSYS_NO_PATHCONV=1 docker exec -i "$NAME" bash -s <<INNER1
$COMMON
wait_ready || { echo "FAIL: the throw-away server did not become ready"; exit 1; }
q "INSTALL SONAME 'campus_audit';" >/dev/null
echo "Server: \$(q "SELECT @@version"), campus_audit \$(q "SELECT PLUGIN_AUTH_VERSION FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit'"), readable_by_all \$(q "SELECT @@GLOBAL.campus_audit_readable_by_all")"
q "CREATE DATABASE watched; CREATE TABLE watched.t (id INT AUTO_INCREMENT PRIMARY KEY, c CHAR(20));
   SET GLOBAL campus_audit_databases = 'watched'" >/dev/null
ACTIVE=\$(q "SELECT @@GLOBAL.campus_audit_file_path")

# refused <description> <path> <reason>: SET GLOBAL fails with ER 1231 and the
# reason; the active file stays.
refused() {
    local out
    out=\$(timeout 15 \$CLIENT -e "SET GLOBAL campus_audit_file_path = '\$2'" 2>&1)
    local rc=\$?
    if [ "\$rc" = 124 ]; then fail "\$1: no answer within 15 s"; return; fi
    if printf '%s' "\$out" | grep -q "ERROR 1231"; then pass "\$1"; else fail "\$1: \$out"; fi
    # through stdin: with -e the client stops at the error and never shows the warnings
    out=\$(printf "SET GLOBAL campus_audit_file_path = '%s';\nSHOW WARNINGS;\n" "\$2" | timeout 15 \$CLIENT --force 2>&1)
    printf '%s' "\$out" | grep -q -- "\$3" && pass "\$1: the reason is given" || fail "\$1: no '\$3' in: \$out"
    [ "\$(q "SELECT @@GLOBAL.campus_audit_file_path")" = "\$ACTIVE" ] && pass "\$1: the active log is kept" \
        || fail "\$1: the active log changed"
}
# unchanged <description> <file> <fingerprint before>
unchanged() {
    [ "\$(fingerprint "\$2")" = "\$3" ] && pass "\$1" || fail "\$1: \$3 -> \$(fingerprint "\$2")"
}

echo "-- attacks with disposable decoys (all in \$D, all created by this test)"
printf '{"ts":"decoy"}\n' > \$D/decoy.jsonl; chown mysql:mysql \$D/decoy.jsonl; chmod 0640 \$D/decoy.jsonl
before=\$(fingerprint \$D/decoy.jsonl)

ln -s \$D/decoy.jsonl \$D/symlink.jsonl
refused "a symbolic link to a log-like file is refused" "\$D/symlink.jsonl" "symbolic link"
unchanged "its target is unchanged (content, mode, owner, links)" \$D/decoy.jsonl "\$before"

printf '{"ts":"decoy2"}\n' > \$D/decoy2.jsonl; chown mysql:mysql \$D/decoy2.jsonl; chmod 0640 \$D/decoy2.jsonl
ln \$D/decoy2.jsonl \$D/hardlink.jsonl
before2=\$(fingerprint \$D/decoy2.jsonl)
refused "a hard link to a log-like file is refused" "\$D/hardlink.jsonl" "hard links"
refused "the same file under its first name is refused too" "\$D/decoy2.jsonl" "hard links"
unchanged "the hard-linked file is unchanged" \$D/decoy2.jsonl "\$before2"

printf '{"ts":"other"}\n' > \$D/other_user.jsonl; chown 65534:65534 \$D/other_user.jsonl; chmod 0666 \$D/other_user.jsonl
before3=\$(fingerprint \$D/other_user.jsonl)
refused "a log-like file of another OS user, writable for the server, is refused" "\$D/other_user.jsonl" "another OS user"
unchanged "that file is unchanged" \$D/other_user.jsonl "\$before3"

: > \$D/table.MYD; chown mysql:mysql \$D/table.MYD; chmod 0660 \$D/table.MYD
before4=\$(fingerprint \$D/table.MYD)
refused "an empty file named like a table file is refused" "\$D/table.MYD" "must end in .jsonl"
unchanged "it stays empty, mode unchanged" \$D/table.MYD "\$before4"

refused "a new file whose name does not end in .jsonl is refused" "\$D/new_log.txt" "must end in .jsonl"
[ ! -e \$D/new_log.txt ] && pass "and is not created" || fail "new_log.txt was created"

mkfifo \$D/noreader.fifo; chown mysql:mysql \$D/noreader.fifo
refused "a FIFO without a reader is refused at once" "\$D/noreader.fifo" "FIFO without a reader"

printf '{"ts":"x"}\n' > \$D/old_log.jsonl; chown mysql:mysql \$D/old_log.jsonl; chmod 0640 \$D/old_log.jsonl
q "SET GLOBAL campus_audit_file_path = '\$D/old_log.jsonl'" >/dev/null
[ "\$(q "SELECT @@GLOBAL.campus_audit_file_path")" = "\$D/old_log.jsonl" ] && pass "an existing campus_audit log of the server's own is accepted" \
    || fail "an existing campus_audit log was refused"
[ "\$(stat -c %a \$D/old_log.jsonl)" = 640 ] && pass "its permissions are not widened (readable_by_all applies to new files only)" \
    || fail "its mode changed to \$(stat -c %a \$D/old_log.jsonl)"
q "SET GLOBAL campus_audit_file_path = '\$D/new_log.jsonl'" >/dev/null
[ -n "\$(find \$D/new_log.jsonl -perm -o=r)" ] && pass "a new log is created readable by others (readable_by_all)" \
    || fail "new_log.jsonl mode \$(stat -c %a \$D/new_log.jsonl)"

echo "-- rotation, recovery and restart still work"
q "INSERT INTO watched.t (c) VALUES ('before rotation')" >/dev/null
mv \$D/new_log.jsonl \$D/new_log.jsonl.1
q "SET GLOBAL campus_audit_reopen_now = ON" >/dev/null
q "INSERT INTO watched.t (c) VALUES ('after rotation')" >/dev/null
[ -f \$D/new_log.jsonl ] && grep -q '"event":"table_write"' \$D/new_log.jsonl && pass "rotation: reopen_now creates the new file and records go there" \
    || fail "rotation: no new log"
grep -q '"event":"table_write"' \$D/new_log.jsonl.1 && pass "rotation: the renamed file keeps the earlier records" \
    || fail "rotation: the renamed file lost its records"
q "SET GLOBAL campus_audit_file_path = '/dev/full'" >/dev/null
q "INSERT INTO watched.t (c) VALUES ('lost')" >/dev/null
[ "\$(status_of CAMPUS_AUDIT_STATE)" = DEGRADED ] && pass "recovery: a write failure (/dev/full, a character device) makes the plugin DEGRADED" \
    || fail "recovery: state \$(status_of CAMPUS_AUDIT_STATE)"
q "SET GLOBAL campus_audit_file_path = '\$D/new_log.jsonl'" >/dev/null
[ "\$(status_of CAMPUS_AUDIT_STATE)" = ACTIVE ] && grep -q '"event":"audit_gap"' \$D/new_log.jsonl \
    && pass "recovery: back to the existing log, ACTIVE, with an audit_gap record" \
    || fail "recovery: state \$(status_of CAMPUS_AUDIT_STATE)"
echo "== phase1: \$PASS passed, \$FAIL failed"
[ "\$FAIL" = 0 ]
INNER1
phase1=$?

echo "-- restarting the server (the plugin is loaded from mysql.plugin and reopens its existing log)"
docker restart "$NAME" >/dev/null || { echo "FAIL: restart"; exit 1; }

MSYS_NO_PATHCONV=1 docker exec -i "$NAME" bash -s <<INNER2
$COMMON
wait_ready || { echo "FAIL: the server did not come back"; exit 1; }
LOG=\$(q "SELECT @@GLOBAL.campus_audit_file_path")
[ "\$(status_of CAMPUS_AUDIT_STATE)" = ACTIVE ] && pass "restart: the plugin is ACTIVE on its existing log (\$LOG)" \
    || fail "restart: state \$(status_of CAMPUS_AUDIT_STATE)"
[ "\$(grep -c '"event":"plugin_start"' "\$LOG")" -ge 2 ] && pass "restart: the existing log was appended to (two plugin_start records)" \
    || fail "restart: plugin_start records: \$(grep -c '"event":"plugin_start"' "\$LOG")"
echo "== phase2: \$PASS passed, \$FAIL failed"
[ "\$FAIL" = 0 ]
INNER2
phase2=$?
[ "$phase1" = 0 ] && [ "$phase2" = 0 ]
