#!/usr/bin/env bash
# Life cycle of the generated demo student against the RUNNING Docker stack:
# real MariaDB, real web application, real HTTP logins.
#
#   make up && bash tests/integration/test_demo_lifecycle.sh
#
# What it proves, in this order:
#
#   1. fresh installation   the credential file exists, is private, and logs in
#   2. role                 the session is a student: /admin/audit is 403 and
#                           the Audit Lab's "all users" scope is refused
#   3. wrong password       is rejected (401)
#   4. storage              MariaDB holds a Werkzeug hash, never the password
#   5. restart              `make up` again, and a restart of both containers:
#                           same file, same stored hash, login still works
#   6. existing database,   `make up` changes nothing, writes no file and says
#      file missing         how to recover; putting the file back works again
#   7. foreign file         a file with another password is neither used nor
#                           overwritten, and the stored password is not changed
#   8. interrupted update   a leftover .pending file is resolved from what
#                           MariaDB really holds
#   9. explicit rotation    `make reset-demo`: new file, new hash, the old
#                           password stops working, the role is still student
#  10. secrecy              neither password appears in any output of the run
#
# It runs on the machine that ran `make up` (Linux; needs make, Docker Compose
# and sha256sum).  The HTTP logins are made inside the web container
# (tests/integration/http_login.py), so no published port is needed.
#
# Effects on the stack it is run against: the demo password is rotated once
# (step 9) and .demo-credentials then holds the new one; two failed logins
# are recorded by the application's login throttle.  Nothing else is changed;
# if the script is interrupted, the original credential file is put back.
# The volume-recreation case ("file present, account missing") needs a deleted
# database volume and is therefore covered by tests/shell/test_demo_bootstrap.sh
# and, in CI, by the fresh-checkout run itself.

set -u
cd "$(dirname "$0")/../.."
COMPOSE=(${COMPOSE:-docker compose})
MAKE=${MAKE:-make}
EMAIL=demo.student@frantastic.local
CRED=.demo-credentials
BACKUP=$CRED.lifecycle-backup
LOG=${LIFECYCLE_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/frantastic-demo-lifecycle.XXXXXX")}
mkdir -p "$LOG"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

[ -f .env ] || { echo "test_demo_lifecycle: .env not found; run make up first" >&2; exit 2; }
[ -f "$CRED" ] || { echo "test_demo_lifecycle: $CRED not found; run make up first (it creates the demo student)" >&2; exit 2; }
[ ! -e "$BACKUP" ] || { echo "test_demo_lifecycle: $BACKUP exists from an interrupted run; inspect and remove it first" >&2; exit 2; }

restore() { if [ -e "$BACKUP" ]; then mv -f -- "$BACKUP" "$CRED"; echo "(restored the original $CRED)"; fi; rm -f -- "$CRED.pending"; }
trap restore EXIT

root_password=$(sed -n 's/^MARIADB_ROOT_PASSWORD=//p' .env | tail -n 1)
sql() { MYSQL_PWD=$root_password "${COMPOSE[@]}" exec -T -e MYSQL_PWD mariadb mariadb -uroot --batch --skip-column-names -e "$1" 2>&1 | tr -d '\r'; }
login() {   # login <password>: one line, see tests/integration/http_login.py
    LOGIN_EMAIL=$EMAIL LOGIN_PASSWORD=$1 "${COMPOSE[@]}" exec -T -e LOGIN_EMAIL -e LOGIN_PASSWORD web python - < tests/integration/http_login.py 2>&1 | tr -d '\r'
}
password_of() { sed -n 2p "$1" | tr -d '\r'; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
stored_hash() { sql "SELECT password_hash FROM university_resources.users WHERE email = '$EMAIL';"; }
up() {      # up <log name>: make up with its whole output captured
    "$MAKE" --no-print-directory up > "$LOG/$1.txt" 2>&1 < /dev/null
}
said() { grep -qF -- "$2" "$LOG/$1.txt"; }
STUDENT="login=302 session=yes admin_audit=403 events_scope=mine items_home=200"
REJECTED="login=401 session=no admin_audit=302 events_scope=- items_home=302"

# ---------------------------------------------------------------- 1-4 fresh installation
first=$(password_of "$CRED")
if [ "$(stat -c '%a' "$CRED")" = 600 ] && [ ! -L "$CRED" ] && [ "$(wc -l < "$CRED" | tr -d ' ')" = 2 ] \
   && [ "$(sed -n 1p "$CRED" | tr -d '\r')" = "$EMAIL" ] && printf '%s' "$first" | grep -Eq '^[A-Za-z0-9_-]{20,}$'; then
    pass "credential file: two lines (e-mail address, password), mode 0600, not a link"
else fail "credential file format or mode" "mode $(stat -c '%a' "$CRED")"; fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git check-ignore -q "$CRED" && [ -z "$(git status --porcelain -- "$CRED" "$CRED.pending")" ]; then pass "credential file is git-ignored and invisible to git status"
    else fail "credential file is git-ignored"; fi
fi
got=$(login "$first")
if [ "$got" = "$STUDENT" ]; then pass "login with the generated credential succeeds; the session is a student without administrator access"
else fail "login with the generated credential" "$got"; fi
got=$(login "not-the-password-$RANDOM$RANDOM")
if [ "$got" = "$REJECTED" ]; then pass "a wrong password is rejected (401, no session)"
else fail "a wrong password is rejected" "$got"; fi
first_hash=$(stored_hash)
got=$(sql "SELECT CONCAT_WS('|', role, is_active, full_name, password_hash REGEXP '^(scrypt|pbkdf2):', COUNT(*) OVER ()) FROM university_resources.users WHERE email = '$EMAIL';")
if [ "$got" = "student|1|Demo Student|1|1" ]; then pass "MariaDB: exactly one demo row, role student, active, Werkzeug hash"
else fail "MariaDB demo row" "$got"; fi
case "$first_hash" in *"$first"*) fail "the stored value must not contain the password" ;; *) pass "MariaDB stores a hash that does not contain the password" ;; esac
got=$(sql "UPDATE university_resources.users SET role = 'admin' WHERE email = '$EMAIL';")
if printf '%s' "$got" | grep -q "ERROR 4025"; then pass "the server refuses to give the demo identity the administrator role (ER 4025, as root)"
else fail "promotion of the demo identity is refused" "${got:-no error}"; fi

# ---------------------------------------------------------------- 5 restart
first_sha=$(sha_of "$CRED")
if up 05-restart-make-up && said 05-restart-make-up "Demo student credential is valid; no rotation performed." \
   && [ "$(sha_of "$CRED")" = "$first_sha" ] && [ "$(stored_hash)" = "$first_hash" ] && [ "$(login "$first")" = "$STUDENT" ]; then
    pass "make up on the running installation: no rotation, same file, same stored hash, login works"
else fail "make up on the running installation" "$(tail -n 5 "$LOG/05-restart-make-up.txt")"; fi
"${COMPOSE[@]}" restart mariadb web > "$LOG/05-compose-restart.txt" 2>&1
if up 05-after-container-restart && [ "$(sha_of "$CRED")" = "$first_sha" ] && [ "$(stored_hash)" = "$first_hash" ] \
   && [ "$(login "$first")" = "$STUDENT" ]; then
    pass "after a restart of both containers the same credential still logs in"
else fail "after a restart of both containers" "$(tail -n 5 "$LOG/05-after-container-restart.txt")"; fi

# ---------------------------------------------------------------- 6 existing database, file missing
mv -- "$CRED" "$BACKUP"
if up 06-file-missing && said 06-file-missing "NOTICE" && said 06-file-missing "NOT changed" && said 06-file-missing "make reset-demo" \
   && [ ! -e "$CRED" ] && [ ! -e "$CRED.pending" ] && [ "$(stored_hash)" = "$first_hash" ]; then
    pass "existing database, credential file missing: make up succeeds, changes no password, writes no file, names the recovery"
else fail "existing database, credential file missing" "$(tail -n 8 "$LOG/06-file-missing.txt")"; fi
if [ "$(login "$first")" = "$STUDENT" ]; then pass "the password that was valid before is still valid (nothing was rotated)"
else fail "the previous password still works"; fi
mv -- "$BACKUP" "$CRED"
if up 06-file-restored && said 06-file-restored "no rotation performed" && [ "$(sha_of "$CRED")" = "$first_sha" ]; then
    pass "putting the file back is recognised without any change"
else fail "putting the file back" "$(tail -n 5 "$LOG/06-file-restored.txt")"; fi

# ---------------------------------------------------------------- 7 a file that belongs to another database
cp -p -- "$CRED" "$BACKUP"
foreign="Foreign-$RANDOM-$RANDOM-abcdefghij"
printf '%s\n%s\n' "$EMAIL" "$foreign" > "$CRED"; chmod 600 "$CRED"; foreign_sha=$(sha_of "$CRED")
if up 07-foreign-file && said 07-foreign-file "does not match" && said 07-foreign-file "Nothing was changed" \
   && [ "$(sha_of "$CRED")" = "$foreign_sha" ] && [ "$(stored_hash)" = "$first_hash" ]; then
    pass "a credential file with another password: the file is not overwritten and the stored password is not changed"
else fail "foreign credential file" "$(tail -n 8 "$LOG/07-foreign-file.txt")"; fi
mv -f -- "$BACKUP" "$CRED"

# ---------------------------------------------------------------- 8 interrupted update
printf '%s\n%s\n' "$EMAIL" "Pending-$RANDOM-$RANDOM-abcdefghij" > "$CRED.pending"; chmod 600 "$CRED.pending"
if up 08-pending-never-applied && said 08-pending-never-applied "never reached the database" && [ ! -e "$CRED.pending" ] \
   && [ "$(sha_of "$CRED")" = "$first_sha" ] && [ "$(stored_hash)" = "$first_hash" ]; then
    pass "a leftover pending file whose password never reached MariaDB is discarded; the working credential is kept"
else fail "leftover pending file (never applied)" "$(tail -n 8 "$LOG/08-pending-never-applied.txt")"; fi

# ---------------------------------------------------------------- 9 explicit rotation
"$MAKE" --no-print-directory reset-demo > "$LOG/09-reset-demo.txt" 2>&1 < /dev/null; status=$?
second=$(password_of "$CRED"); second_hash=$(stored_hash)
if [ "$status" -eq 0 ] && said 09-reset-demo "rotated and verified" && [ "$second" != "$first" ] && [ "$second_hash" != "$first_hash" ] \
   && [ "$(stat -c '%a' "$CRED")" = 600 ] && [ ! -e "$CRED.pending" ]; then
    pass "make reset-demo: a new password in the file (mode 0600) and a new hash in MariaDB"
else fail "make reset-demo" "$(tail -n 5 "$LOG/09-reset-demo.txt")"; fi
if [ "$(login "$second")" = "$STUDENT" ]; then pass "the new credential logs in and is still a student"
else fail "login with the rotated credential"; fi
if [ "$(login "$first")" = "$REJECTED" ]; then pass "the previous password no longer works"
else fail "the previous password is rejected after rotation"; fi
# The interrupted-rotation case with a database that already holds the new
# password: the stale file is replaced by the pending one.
cp -p -- "$CRED" "$CRED.pending"; printf '%s\n%s\n' "$EMAIL" "$first" > "$CRED"; chmod 600 "$CRED"
if up 09-pending-already-applied && said 09-pending-already-applied "already held the new password" && [ ! -e "$CRED.pending" ] \
   && [ "$(password_of "$CRED")" = "$second" ] && [ "$(stored_hash)" = "$second_hash" ] && [ "$(login "$second")" = "$STUDENT" ]; then
    pass "interrupted rotation after MariaDB was updated: the next start completes it from the pending file"
else fail "interrupted rotation (database already updated)" "$(tail -n 8 "$LOG/09-pending-already-applied.txt")"; fi
if [ "$(sql "SELECT COUNT(*) FROM university_resources.users WHERE email = '$EMAIL' AND role = 'student';")" = 1 ]; then
    pass "after every step there is still exactly one demo row, with the role student"
else fail "exactly one demo student row"; fi

# ---------------------------------------------------------------- 10 secrecy
leak=0
for secret in "$first" "$second" "$foreign"; do
    if grep -rqF -- "$secret" "$LOG"; then leak=1; fi
done
if [ "$leak" = 0 ] && ! grep -rqE '(scrypt|pbkdf2):[0-9a-z:]+\$' "$LOG"; then
    pass "no password and no password hash appears in the output of make up / make reset-demo ($(ls "$LOG" | wc -l | tr -d ' ') captured logs)"
else fail "a password or hash appears in a captured log (directory kept: $LOG)"; fi

echo "== $PASS passed, $FAIL failed   (logs: $LOG)"
[ "$FAIL" -eq 0 ]
