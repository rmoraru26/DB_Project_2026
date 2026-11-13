#!/usr/bin/env bash
# Regression tests for the administrator password handling and login
# diagnostics: scripts/mariadb_admin_auth.sh and its callers post_start.sh,
# demo.sh, provision_local_admin_db.sh and doctor.sh.  A fake mariadb client
# records only whether MYSQL_PWD arrived (missing / empty / match / mismatch)
# and simulates the server's answer.  Dummy passwords only; no server, no Docker.
#
#   bash tests/shell/test_admin_auth.sh
set -u
cd "$(dirname "$0")/../.."
repo=$PWD
work=$(mktemp -d "${TMPDIR:-/tmp}/frantastic shell tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
GOOD="good-dummy-$RANDOM$RANDOM"
WRONG="wrong-dummy-$RANDOM$RANDOM"
passed=0; failed=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failed=$((failed + 1)); echo "FAIL: $1"; printf '      %s\n' "$out" | head -n 20; }

cat > "$work/bin/mariadb" <<'FAKE'
#!/usr/bin/env bash
if [ "${MYSQL_PWD+x}" != x ]; then state=missing
elif [ -z "$MYSQL_PWD" ]; then state=empty
elif [ "$MYSQL_PWD" = "${FAKE_SERVER_PWD:-}" ]; then state=match
else state=mismatch; fi
case " $* " in *" -e "*) sql="$*" ;; *) sql=$(cat) ;; esac
printf '%s\n' "$state" >> "$FAKE_LOG"
case ${FAKE_MODE:-server} in
    strip) state=missing ;;
    unreachable) echo "ERROR 2002 (HY000): Can't connect to local server through socket '/run/mysqld/mysqld.sock' (2)" >&2; exit 1 ;;
    syntax) echo "ERROR 1064 (42000): You have an error in your SQL syntax" >&2; exit 1 ;;
    missing-client) echo "mariadb: command not found" >&2; exit 127 ;;
esac
case "$state" in
    match) ;;
    missing|empty) echo "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: NO)" >&2; exit 1 ;;
    *) echo "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)" >&2; exit 1 ;;
esac
case "$sql" in
    *PLUGIN_STATUS*) echo ACTIVE ;;
    *bootstrap_pending*) echo "1 0 MISSING" ;;
    *"SELECT 1"*) echo 1 ;;
esac
exit 0
FAKE
cat > "$work/bin/fakecompose" <<'FAKE'
#!/usr/bin/env bash
# Stands in for `docker compose` in doctor.sh: ps, and exec into "mariadb",
# which runs the fake client with the inherited environment (like -e NAME).
case "$1" in
    ps) echo "mariadb running healthy" ;;
    exec) shift
          while [ $# -gt 0 ]; do case "$1" in -T) shift ;; -e) shift 2 ;; mariadb) shift; break ;; *) shift ;; esac; done
          exec "$@" ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/bin/docker"
chmod +x "$work/bin/mariadb" "$work/bin/fakecompose" "$work/bin/docker"
: > "$work/all-output"

# run <dir> <command...>, after env assignments given in RUN_ENV (array).
run() {
    local dir=$1; shift
    : > "$work/log"
    out=$(cd "$dir" && env -u MYSQL_PWD -u MARIADB_ROOT_PASSWORD -u CAMPUS_APP_PASSWORD -u DB_ADMIN_USER \
          -u FAKE_MODE -u MARIADB_CLIENT -u COMPOSE \
          FAKE_LOG="$work/log" FAKE_SERVER_PWD="$GOOD" PATH="$work/bin:$PATH" MARIADB_CLIENT=mariadb \
          "${RUN_ENV[@]}" "$@" 2>&1 </dev/null)
    status=$?
    calls=$(wc -l < "$work/log" | tr -d ' ')
    states=$(sort -u "$work/log" | tr '\n' ' ' | sed 's/ $//')
    printf '%s\n' "$out" >> "$work/all-output"
}
has() { printf '%s' "$out" | grep -qF -- "$1"; }

# ------------------------------------------------------------ credential matrix (post_start.sh)
check_ok() {  # <label>
    if [ "$status" -eq 0 ] && [ "$states" = match ] && [ "$calls" -gt 0 ]; then pass "$1"; else fail "$1 (status=$status states='$states' calls=$calls)"; fi
}
check_refused() {  # <label> <expected text>
    if [ "$status" -eq 2 ] && [ "$calls" -eq 0 ] && has "$2"; then pass "$1"; else fail "$1 (status=$status calls=$calls)"; fi
}
RUN_ENV=(MYSQL_PWD="$GOOD" MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/post_start.sh
check_ok "post_start: MYSQL_PWD and MARIADB_ROOT_PASSWORD equal"
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/post_start.sh
check_ok "post_start: MYSQL_PWD absent, falls back to MARIADB_ROOT_PASSWORD"
RUN_ENV=(MYSQL_PWD= MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/post_start.sh
check_ok "post_start: MYSQL_PWD empty, falls back to MARIADB_ROOT_PASSWORD"
RUN_ENV=(MYSQL_PWD="$GOOD"); run "$repo" bash scripts/post_start.sh
check_ok "post_start: MYSQL_PWD only (Linux host / native server caller)"
RUN_ENV=(MARIADB_ROOT_PASSWORD=); run "$repo" bash scripts/post_start.sh
check_refused "post_start: MARIADB_ROOT_PASSWORD empty, refused before the client runs" "no MariaDB root password is available"
RUN_ENV=(); run "$repo" bash scripts/post_start.sh
check_refused "post_start: no password at all, refused before the client runs" "no MariaDB root password is available"
RUN_ENV=(MYSQL_PWD="$WRONG" MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/post_start.sh
check_refused "post_start: conflicting MYSQL_PWD and MARIADB_ROOT_PASSWORD are refused" "both set but differ"
RUN_ENV=(DB_ADMIN_USER=dba MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/post_start.sh
check_refused "post_start: the root password is not used for another admin user" "no password for the MariaDB administrator 'dba'"
RUN_ENV=(DB_ADMIN_USER=dba MYSQL_PWD="$GOOD" MARIADB_ROOT_PASSWORD="$WRONG"); run "$repo" bash scripts/post_start.sh
check_ok "post_start: another admin user uses MYSQL_PWD regardless of MARIADB_ROOT_PASSWORD"

# ------------------------------------------------------------ diagnostics (post_start.sh)
RUN_ENV=(MYSQL_PWD="$GOOD" FAKE_SERVER_PWD="$WRONG"); run "$repo" bash scripts/post_start.sh
if [ "$status" -eq 3 ] && has "using password: YES" && has "rejects the root password" && has "make repair-credentials" \
   && has "Windows:" && ! has "sent NO password"; then pass "post_start: rejected password (YES) explains the volume/.env mismatch"
else fail "post_start: rejected password diagnosis (status=$status)"; fi
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD" FAKE_MODE=strip); run "$repo" bash scripts/post_start.sh
if [ "$status" -eq 3 ] && has "using password: NO" && has "sent NO password" && ! has "rejects the root password" \
   && ! has "initialised with the passwords"; then pass "post_start: missing password (NO) is not blamed on the volume"
else fail "post_start: missing password diagnosis (status=$status)"; fi
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD" FAKE_MODE=unreachable); run "$repo" bash scripts/post_start.sh
if [ "$status" -eq 3 ] && has "ERROR 2002" && has "could not connect" && ! has "ERROR 1045" && ! has "rejects"; then
    pass "post_start: unreachable server is not an authentication failure"
else fail "post_start: unreachable diagnosis (status=$status)"; fi
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD" FAKE_MODE=syntax); run "$repo" bash scripts/post_start.sh
if [ "$status" -eq 3 ] && has "ERROR 1064" && has "Unexpected error"; then pass "post_start: other client errors keep their own message"
else fail "post_start: other error diagnosis (status=$status)"; fi
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD" FAKE_MODE=missing-client); run "$repo" bash scripts/post_start.sh
if [ "$status" -eq 3 ] && has "client program was not found"; then pass "post_start: missing client program is reported"
else fail "post_start: missing client diagnosis (status=$status)"; fi

# ------------------------------------------------------------ helper under set -u, export to children
RUN_ENV=(EXPECT="$GOOD" MARIADB_ROOT_PASSWORD="$GOOD")
run "$repo" bash -u -c '. scripts/mariadb_admin_auth.sh; frantastic_require_admin_password root t && bash -c "[ \"\${MYSQL_PWD:-}\" = \"\$EXPECT\" ]" && echo EXPORTED'
if [ "$status" -eq 0 ] && has EXPORTED && ! has "unbound variable"; then pass "helper (set -u): resolved password is exported to child processes"
else fail "helper export under set -u (status=$status)"; fi
RUN_ENV=()
run "$repo" bash -u -c '. scripts/mariadb_admin_auth.sh; frantastic_require_admin_password root t; echo "rc=$?"'
if has "rc=2" && ! has "unbound variable"; then pass "helper (set -u): unset variables give a clean refusal"
else fail "helper refusal under set -u"; fi

# ------------------------------------------------------------ demo.sh and provision_local_admin_db.sh
RUN_ENV=(); run "$repo" bash scripts/demo.sh
check_refused "demo: no password, refused before the client runs" "no MariaDB root password is available"
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/demo.sh
if [ "$status" -eq 0 ] && [ "$(head -n 1 "$work/log")" = match ]; then pass "demo: runs with the service password only (Windows launcher path)"
else fail "demo: service password (status=$status)"; fi
RUN_ENV=(MYSQL_PWD="$WRONG" MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/demo.sh
check_refused "demo: conflicting passwords are refused" "both set but differ"
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/provision_local_admin_db.sh state
if [ "$status" -eq 0 ] && [ "$states" = match ] && has "1 0 MISSING"; then pass "provision_local_admin_db: state with the service password only"
else fail "provision state (status=$status states='$states')"; fi
RUN_ENV=(MYSQL_PWD="$GOOD" MARIADB_ROOT_PASSWORD="$GOOD" 'FRANTASTIC_ADMIN_HASH=pbkdf2:sha256:1000$abc$def'); run "$repo" bash scripts/provision_local_admin_db.sh bootstrap
if [ "$status" -eq 0 ] && [ "$states" = match ]; then pass "provision_local_admin_db: bootstrap with equal MYSQL_PWD (Linux make path)"
else fail "provision bootstrap (status=$status states='$states')"; fi
RUN_ENV=(); run "$repo" bash scripts/provision_local_admin_db.sh state
check_refused "provision_local_admin_db: no password, refused before the client runs" "no MariaDB root password is available"
RUN_ENV=(MYSQL_PWD="$WRONG" MARIADB_ROOT_PASSWORD="$GOOD"); run "$repo" bash scripts/provision_local_admin_db.sh state
check_refused "provision_local_admin_db: conflicting passwords are refused" "both set but differ"
RUN_ENV=(); run "$repo" bash scripts/provision_local_admin_db.sh frobnicate
check_refused "provision_local_admin_db: an unknown action is reported as usage error, even without a password" "usage: provision_local_admin_db.sh"
RUN_ENV=(FRANTASTIC_ADMIN_HASH='not-a-hash'); run "$repo" bash scripts/provision_local_admin_db.sh bootstrap
check_refused "provision_local_admin_db: an invalid hash is reported before the password check" "A valid generated password hash is required"
RUN_ENV=(MARIADB_ROOT_PASSWORD="$GOOD" FRANTASTIC_ADMIN_HASH='not-a-hash'); run "$repo" bash scripts/provision_local_admin_db.sh rotate
check_refused "provision_local_admin_db: an invalid hash never reaches the client" "A valid generated password hash is required"

# ------------------------------------------------------------ doctor.sh (copied next to a dummy .env)
doc="$work/doctor tree"
mkdir -p "$doc/scripts"
cp scripts/doctor.sh scripts/mariadb_admin_auth.sh "$doc/scripts/"
printf 'MARIADB_ROOT_PASSWORD=%s\nCAMPUS_APP_PASSWORD=%s\nSECRET_KEY=%s\n' "$GOOD" "$GOOD-app" "$GOOD-key" > "$doc/.env"
RUN_ENV=(COMPOSE=fakecompose); run "$doc" bash scripts/doctor.sh
if has "[ OK ] root login with the password from .env"; then pass "doctor: working root login is reported OK"; else fail "doctor: root OK"; fi
RUN_ENV=(COMPOSE=fakecompose FAKE_SERVER_PWD="$WRONG"); run "$doc" bash scripts/doctor.sh
if [ "$status" -ne 0 ] && has "[FAIL] root login" && has "ERROR 1045" && has "rejects the root password" && has "make repair-credentials"; then
    pass "doctor: rejected password (YES) is explained"
else fail "doctor: rejected password (status=$status)"; fi
RUN_ENV=(COMPOSE=fakecompose FAKE_MODE=strip); run "$doc" bash scripts/doctor.sh
if [ "$status" -ne 0 ] && has "using password: NO" && has "sent NO password" && ! has "rejects the root password"; then
    pass "doctor: missing password (NO) is not blamed on the volume"
else fail "doctor: missing password (status=$status)"; fi
RUN_ENV=(COMPOSE=fakecompose FAKE_MODE=unreachable); run "$doc" bash scripts/doctor.sh
if [ "$status" -ne 0 ] && has "could not connect" && ! has "rejects the root password"; then pass "doctor: unreachable server is distinguished"
else fail "doctor: unreachable (status=$status)"; fi

# ------------------------------------------------------------ no dummy password in any output
if grep -qF -e "$GOOD" -e "$WRONG" "$work/all-output"; then out="(a dummy password was printed)"; fail "no password appears in any output"
else pass "no password appears in any output"; fi

echo "Shell credential tests: $passed passed, $failed failed."
[ "$failed" -eq 0 ]
