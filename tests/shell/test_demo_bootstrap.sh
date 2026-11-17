#!/usr/bin/env bash
# State-machine tests of scripts/bootstrap_demo.sh (the per-installation demo
# student of `make up` / `make reset-demo`).  No server and no Docker: a fake
# `docker compose` keeps the "database" in a few files and answers exactly the
# commands the script sends to the two containers:
#
#   web      python /app/bootstrap_demo.py --password-only | --hash-environment | --check-environment
#   mariadb  bash /usr/local/share/campus/scripts/provision_local_demo_db.sh state | bootstrap | rotate
#
# What is proved here: a first start creates the account and a private file;
# a restart changes nothing; an existing database without the local file is
# left alone; a re-created database reuses the saved password; rotation
# happens only on request; every interrupted run can be re-run; unsafe files
# are refused; and no password ever reaches the output.  The real container
# side is covered by tests/database/test_demo_student.sh (procedures,
# constraint) and tests/integration/test_demo_lifecycle.sh (running stack).
#
#   bash tests/shell/test_demo_bootstrap.sh
#
# Runs in a temporary copy; the working tree is not touched.  Needs a
# filesystem that enforces POSIX file modes and GNU coreutils (`stat -c`,
# `mv -T`); it has been run on Linux only (macOS not tested).  Under Git Bash on
# Windows it reports SKIP, the Windows launcher has its own test
# (tests/windows/test_demo_credentials.ps1).
set -u
cd "$(dirname "$0")/../.."
repo=$PWD
work=$(mktemp -d "${TMPDIR:-/tmp}/frantastic demo tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

probe="$work/mode-probe"
: > "$probe"; chmod 600 "$probe"
if [ "$(stat -c '%a' "$probe" 2>/dev/null)" != 600 ] || { chmod 644 "$probe"; [ "$(stat -c '%a' "$probe")" != 644 ]; }; then
    echo "SKIP: this filesystem does not enforce POSIX file modes (or GNU stat is missing);"
    echo "      scripts/bootstrap_demo.sh is the Linux path. Windows: tests/windows/test_demo_credentials.ps1"
    exit 0
fi

tree="$work/project tree"
mkdir -p "$tree/scripts" "$work/bin"
cp scripts/bootstrap_demo.sh "$tree/scripts/"
EMAIL=demo.student@frantastic.local
passed=0; failed=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failed=$((failed + 1)); echo "FAIL: $1"; printf '      %s\n' "${out:-}" | head -n 12; }

cat > "$work/bin/fakecompose" <<'FAKE'
#!/usr/bin/env bash
# `docker compose exec [-T] [-e NAME]... <service> <command...>` against a
# file-backed fake.  -e NAME forwards the caller's variable, so the inherited
# environment is the forwarded one.
state=$FAKE_STATE
printf 'CALL %s\n' "$*" >> "$state/calls"
[ "${1:-}" = exec ] || { echo "fakecompose: unexpected: $*" >&2; exit 64; }
shift
service=
while [ $# -gt 0 ]; do
    case "$1" in
        -T) shift ;;
        -e) shift 2 ;;
        mariadb|web) service=$1; shift; break ;;
        *) shift ;;
    esac
done
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
hash_of() { printf 'pbkdf2:sha256:1$fake$%s' "$(sha "$1")"; }
case "$service $*" in
    "web python /app/bootstrap_demo.py --password-only")
        [ "${FAKE_FAIL:-}" = password ] && { echo "generator unavailable" >&2; exit 1; }
        password=$(head -c 18 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
        printf '%s\n' "$password" >> "$FAKE_SECRETS"
        printf '%s\n' "$password" ;;
    "web python /app/bootstrap_demo.py --hash-environment")
        [ -n "${FRANTASTIC_DEMO_PASSWORD:-}" ] || { echo "FRANTASTIC_DEMO_PASSWORD is missing" >&2; exit 2; }
        [ "${FAKE_FAIL:-}" = hash ] && { echo "not-a-hash"; exit 0; }
        printf '%s\n' "$(hash_of "$FRANTASTIC_DEMO_PASSWORD")" ;;
    "web python /app/bootstrap_demo.py --check-environment")
        [ -n "${FRANTASTIC_DEMO_PASSWORD:-}" ] || { echo "FRANTASTIC_DEMO_PASSWORD is missing" >&2; exit 2; }
        [ "${FAKE_FAIL:-}" = check ] && { echo "Could not verify the demo student against MariaDB" >&2; exit 2; }
        if [ ! -f "$state/db_hash" ]; then echo MISSING
        elif [ "$(cat "$state/db_role")" != student ]; then echo NOT_STUDENT
        elif [ "$(cat "$state/db_hash")" != "$(hash_of "$FRANTASTIC_DEMO_PASSWORD")" ]; then echo MISMATCH
        elif [ "$(cat "$state/db_active")" != 1 ]; then echo INACTIVE
        else echo MATCH; fi ;;
    "mariadb bash /usr/local/share/campus/scripts/provision_local_demo_db.sh state")
        [ "${FAKE_FAIL:-}" = state ] && { echo "ERROR 2002 (HY000): Can't connect" >&2; exit 1; }
        if [ -f "$state/db_hash" ]; then echo "$(cat "$state/db_role") $(cat "$state/db_active")"; else echo "MISSING -"; fi ;;
    "mariadb bash /usr/local/share/campus/scripts/provision_local_demo_db.sh bootstrap")
        [ "${FAKE_FAIL:-}" = db ] && { echo "ERROR 2013 (HY000): Lost connection to server during query" >&2; exit 1; }
        if [ -f "$state/db_hash" ]; then echo EXISTS
        else printf '%s' "$FRANTASTIC_DEMO_HASH" > "$state/db_hash"; echo student > "$state/db_role"; echo 1 > "$state/db_active"; echo CREATED; fi
        # The statement was committed, but the client reports a failure.
        [ "${FAKE_FAIL:-}" = after-db ] && exit 1
        exit 0 ;;
    "mariadb bash /usr/local/share/campus/scripts/provision_local_demo_db.sh rotate")
        [ "${FAKE_FAIL:-}" = db ] && { echo "ERROR 2013 (HY000): Lost connection to server during query" >&2; exit 1; }
        if [ ! -f "$state/db_hash" ]; then echo MISSING
        elif [ "$(cat "$state/db_role")" != student ]; then echo NOT_STUDENT
        else printf '%s' "$FRANTASTIC_DEMO_HASH" > "$state/db_hash"; echo ROTATED; fi
        [ "${FAKE_FAIL:-}" = after-db ] && exit 1
        exit 0 ;;
    *) echo "fakecompose: unexpected command for '$service': $*" >&2; exit 64 ;;
esac
FAKE
chmod +x "$work/bin/fakecompose"

state="$work/state"
cred="$tree/.demo-credentials"
pending="$cred.pending"
: > "$work/all-output"
: > "$work/every-secret"        # every password the fake generator produces

new_world() {    # an empty database, no local files
    rm -rf "$state"; mkdir -p "$state"; : > "$state/calls"
    rm -f "$cred" "$pending" "$tree"/.demo-credentials.tmp.*
}
run() {          # run [FAKE_FAIL=...] -- <script arguments...>
    local -a assign=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do assign+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    : > "$state/calls"
    out=$(env -u FRANTASTIC_DEMO_PASSWORD -u FRANTASTIC_DEMO_HASH -u FRANTASTIC_DEMO_CREDENTIAL_FILE -u FAKE_FAIL \
          FAKE_STATE="$state" FAKE_SECRETS="$work/every-secret" COMPOSE="fakecompose" PATH="$work/bin:$PATH" MYSQL_PWD=dummy-root-password \
          "${assign[@]}" bash "$tree/scripts/bootstrap_demo.sh" "$@" 2>&1 </dev/null)
    status=$?
    printf '%s\n' "$out" >> "$work/all-output"
}
has() { printf '%s' "$out" | grep -qF -- "$1"; }
called() { grep -qF -- "$1" "$state/calls"; }
mode_of() { stat -c '%a' "$1"; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
password_in() { sed -n 2p "$1"; }
db_matches() {   # db_matches <password>: the fake database holds exactly its hash
    [ -f "$state/db_hash" ] && [ "$(cat "$state/db_hash")" = "pbkdf2:sha256:1\$fake\$$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)" ]
}
write_file() {   # write_file <path> <password> [mode]
    printf '%s\n%s\n' "$EMAIL" "$2" > "$1"; chmod "${3:-600}" "$1"
}
other_password() { printf 'Other-%s_%s-abcdefgh' "$RANDOM" "$RANDOM"; }

# ------------------------------------------------------------ first installation
new_world
run --
if [ "$status" -eq 0 ] && [ -f "$cred" ] && [ ! -e "$pending" ] && [ "$(mode_of "$cred")" = 600 ] \
   && [ "$(wc -l < "$cred" | tr -d ' ')" = 2 ] && [ "$(sed -n 1p "$cred")" = "$EMAIL" ] \
   && password_in "$cred" | grep -Eq '^[A-Za-z0-9_-]{20,}$' && db_matches "$(password_in "$cred")" \
   && [ "$(cat "$state/db_role")" = student ] && has "created and verified (role: student)"; then
    pass "first start: account created as student, credential file written with mode 0600, no pending file left"
else fail "first start (status=$status)"; fi
if has ".demo-credentials" && has "not printed" && ! has "$(password_in "$cred")"; then
    pass "first start: the output names the file and does not contain the password"
else fail "first start output"; fi
first_sha=$(sha_of "$cred"); first_hash=$(cat "$state/db_hash")

# ------------------------------------------------------------ ordinary restart
run --
if [ "$status" -eq 0 ] && has "no rotation performed" && [ "$(sha_of "$cred")" = "$first_sha" ] \
   && [ "$(cat "$state/db_hash")" = "$first_hash" ] && ! called "--password-only" && ! called " bootstrap" && ! called " rotate"; then
    pass "restart: nothing generated, nothing written, file and stored hash unchanged"
else fail "restart (status=$status)"; fi
run --; run --
if [ "$(sha_of "$cred")" = "$first_sha" ] && [ "$(cat "$state/db_hash")" = "$first_hash" ]; then
    pass "repeated restarts never rotate the credential"
else fail "repeated restarts"; fi

# A file that became group/world readable is tightened, not rejected.
chmod 644 "$cred"; run --
if [ "$status" -eq 0 ] && [ "$(mode_of "$cred")" = 600 ] && [ "$(sha_of "$cred")" = "$first_sha" ]; then
    pass "restart: a too-permissive credential file is set back to mode 0600"
else fail "restart with mode 0644 (status=$status mode=$(mode_of "$cred"))"; fi

# ------------------------------------------------------------ existing database, local file missing
saved_password=$(password_in "$cred"); rm -f "$cred"
run --
if [ "$status" -eq 0 ] && has "NOTICE" && has "NOT changed" && has "make reset-demo" && [ ! -e "$cred" ] && [ ! -e "$pending" ] \
   && [ "$(cat "$state/db_hash")" = "$first_hash" ] && ! called "--password-only" && ! called " bootstrap" && ! called " rotate"; then
    pass "existing database without the local file: password not changed, no file written, recovery explained"
else fail "existing database, missing file (status=$status)"; fi

# ------------------------------------------------------------ file present, account stored with another password
wrong=$(other_password); write_file "$cred" "$wrong"; wrong_sha=$(sha_of "$cred")
run --
if [ "$status" -eq 0 ] && has "NOTICE" && has "does not match" && has "make reset-demo" && [ "$(sha_of "$cred")" = "$wrong_sha" ] \
   && [ "$(cat "$state/db_hash")" = "$first_hash" ] && ! called " bootstrap" && ! called " rotate"; then
    pass "mismatching file: neither the file nor the stored password is changed"
else fail "mismatching file (status=$status)"; fi

# ------------------------------------------------------------ re-created database, saved file reused
write_file "$cred" "$saved_password"; rm -f "$state/db_hash" "$state/db_role" "$state/db_active"
run --
if [ "$status" -eq 0 ] && has "saved local credential" && [ "$(sha_of "$cred")" = "$first_sha" ] && db_matches "$saved_password" \
   && ! called "--password-only"; then
    pass "re-created database: the account is created with the SAVED password; the file is not replaced"
else fail "re-created database (status=$status)"; fi

# ------------------------------------------------------------ explicit rotation
run -- --reset
new_password=$(password_in "$cred")
if [ "$status" -eq 0 ] && has "rotated and verified" && [ "$new_password" != "$saved_password" ] && db_matches "$new_password" \
   && ! db_matches "$saved_password" && [ "$(mode_of "$cred")" = 600 ] && [ ! -e "$pending" ] && called " rotate"; then
    pass "reset: a new password is stored and saved; the previous one no longer matches"
else fail "reset (status=$status)"; fi
new_world
run -- --reset
if [ "$status" -eq 0 ] && db_matches "$(password_in "$cred")" && called " bootstrap" && ! called " rotate"; then
    pass "reset on a database without the account creates it"
else fail "reset without account (status=$status)"; fi

# ------------------------------------------------------------ interrupted runs are completed or discarded
new_world; p=$(other_password); write_file "$pending" "$p"
run --
if [ "$status" -eq 0 ] && has "interrupted demo-student bootstrap" && [ ! -e "$pending" ] && [ "$(password_in "$cred")" = "$p" ] && db_matches "$p" \
   && ! called "--password-only"; then
    pass "interrupted before the database was changed: the pending password is used, not a new one"
else fail "pending, database empty (status=$status)"; fi

new_world; run --; old=$(password_in "$cred"); p=$(other_password)
printf '%s' "pbkdf2:sha256:1\$fake\$$(printf '%s' "$p" | sha256sum | cut -d' ' -f1)" > "$state/db_hash"; write_file "$pending" "$p"
run --
if [ "$status" -eq 0 ] && has "already held the new password" && [ ! -e "$pending" ] && [ "$(password_in "$cred")" = "$p" ] && db_matches "$p"; then
    pass "interrupted after the database was changed: the pending password replaces the stale file"
else fail "pending matches database (status=$status)"; fi

new_world; run --; keep_sha=$(sha_of "$cred"); keep_hash=$(cat "$state/db_hash"); write_file "$pending" "$(other_password)"
run --
if [ "$status" -eq 0 ] && has "never reached the database" && [ ! -e "$pending" ] && [ "$(sha_of "$cred")" = "$keep_sha" ] \
   && [ "$(cat "$state/db_hash")" = "$keep_hash" ]; then
    pass "interrupted rotation that never reached the database: pending file discarded, working file kept"
else fail "pending never applied (status=$status)"; fi

new_world; run --; write_file "$cred" "$(other_password)"; write_file "$pending" "$(other_password)"
cred_sha=$(sha_of "$cred"); pending_sha=$(sha_of "$pending"); keep_hash=$(cat "$state/db_hash")
run --
if [ "$status" -eq 1 ] && has "cannot be reconciled automatically" && has "make reset-demo" && [ "$(sha_of "$cred")" = "$cred_sha" ] \
   && [ "$(sha_of "$pending")" = "$pending_sha" ] && [ "$(cat "$state/db_hash")" = "$keep_hash" ]; then
    pass "irreconcilable state: fails, both files preserved, database untouched, recovery named"
else fail "irreconcilable (status=$status)"; fi
run -- --reset
if [ "$status" -eq 0 ] && [ ! -e "$pending" ] && db_matches "$(password_in "$cred")"; then
    pass "the explicit reset recovers from the irreconcilable state"
else fail "reset after irreconcilable (status=$status)"; fi

# ------------------------------------------------------------ failures during a first start can be retried
new_world; run FAKE_FAIL=db --
kept=$(password_in "$pending" 2>/dev/null)
if [ "$status" -eq 1 ] && [ ! -e "$cred" ] && [ -f "$pending" ] && [ "$(mode_of "$pending")" = 600 ] && [ ! -f "$state/db_hash" ] && has "preserved"; then
    pass "database failure during the first start: exit 1, protected pending file kept, no half-created account"
else fail "db failure on first start (status=$status)"; fi
run --
if [ "$status" -eq 0 ] && [ ! -e "$pending" ] && [ "$(password_in "$cred")" = "$kept" ] && db_matches "$kept"; then
    pass "retry after that failure completes with the same password"
else fail "retry after db failure (status=$status)"; fi

new_world; run FAKE_FAIL=after-db --
kept=$(password_in "$pending" 2>/dev/null)
if [ "$status" -eq 1 ] && [ ! -e "$cred" ] && [ -f "$pending" ] && db_matches "$kept"; then
    pass "failure reported after the row was committed: pending file kept"
else fail "after-db failure (status=$status)"; fi
run --
if [ "$status" -eq 0 ] && [ ! -e "$pending" ] && [ "$(password_in "$cred")" = "$kept" ] && db_matches "$kept"; then
    pass "retry after that failure promotes the pending password without touching the database"
else fail "retry after after-db failure (status=$status)"; fi

new_world; run FAKE_FAIL=hash --
if [ "$status" -eq 1 ] && has "hash generation failed" && [ ! -f "$state/db_hash" ] && [ ! -e "$cred" ]; then
    pass "an invalid hash never reaches the database"
else fail "invalid hash (status=$status)"; fi
new_world; run FAKE_FAIL=state --
if [ "$status" -eq 1 ] && has "cannot inspect the demo account" && [ ! -e "$cred" ] && [ ! -e "$pending" ]; then
    pass "unreachable database: fails before any file is written"
else fail "state failure (status=$status)"; fi
new_world; run FAKE_FAIL=password --
if [ "$status" -eq 1 ] && [ ! -e "$cred" ] && [ ! -e "$pending" ] && [ ! -f "$state/db_hash" ]; then
    pass "password generation failure: nothing written, nothing created"
else fail "password generation failure (status=$status)"; fi
new_world; run --; keep_sha=$(sha_of "$cred"); keep_hash=$(cat "$state/db_hash"); run FAKE_FAIL=db -- --reset
if [ "$status" -eq 1 ] && [ "$(sha_of "$cred")" = "$keep_sha" ] && [ "$(cat "$state/db_hash")" = "$keep_hash" ] && [ -f "$pending" ]; then
    pass "failed rotation: the working credential file and the stored password are both unchanged"
else fail "failed rotation (status=$status)"; fi
run --
if [ "$status" -eq 0 ] && [ ! -e "$pending" ] && [ "$(sha_of "$cred")" = "$keep_sha" ]; then
    pass "start after a failed rotation: pending file discarded, the working credential stays valid"
else fail "start after failed rotation (status=$status)"; fi

# ------------------------------------------------------------ unsafe or foreign files are refused
new_world; run --; real="$work/elsewhere"; cp -p "$cred" "$real"; rm -f "$cred"; ln -s "$real" "$cred"; real_sha=$(sha_of "$real")
run --
if [ "$status" -eq 1 ] && has "preserved" && [ -L "$cred" ] && [ "$(sha_of "$real")" = "$real_sha" ]; then
    pass "a symbolic link in place of the credential file is refused and its target is not modified"
else fail "symlink (status=$status)"; fi
run -- --reset
if [ "$status" -eq 1 ] && has "refusing to replace a symbolic link" && [ "$(sha_of "$real")" = "$real_sha" ]; then
    pass "reset refuses to write through a symbolic link"
else fail "reset through symlink (status=$status)"; fi
rm -f "$cred" "$pending"

new_world; run --; keep_hash=$(cat "$state/db_hash")
printf '%s\n%s\nextra line\n' "$EMAIL" "$(other_password)" > "$cred"; chmod 600 "$cred"; bad_sha=$(sha_of "$cred")
run --
if [ "$status" -eq 1 ] && has "malformed" && [ "$(sha_of "$cred")" = "$bad_sha" ] && [ "$(cat "$state/db_hash")" = "$keep_hash" ]; then
    pass "a malformed credential file is preserved and stops the run"
else fail "malformed file (status=$status)"; fi
printf '%s\n%s\n' "someone.else@example.edu" "$(other_password)" > "$cred"; chmod 600 "$cred"
run --
if [ "$status" -eq 1 ] && [ "$(cat "$state/db_hash")" = "$keep_hash" ]; then pass "a file for another account is not used"
else fail "foreign e-mail in file (status=$status)"; fi
printf '%s\n%s\n' "$EMAIL" "short" > "$cred"; chmod 600 "$cred"
run --
if [ "$status" -eq 1 ] && [ "$(cat "$state/db_hash")" = "$keep_hash" ]; then pass "a file with an implausibly short password is not used"
else fail "short password in file (status=$status)"; fi

# ------------------------------------------------------------ the account must be a student
new_world; run --; echo admin > "$state/db_role"; keep_sha=$(sha_of "$cred"); keep_hash=$(cat "$state/db_hash")
run --
if [ "$status" -eq 1 ] && has "not a student account" && [ "$(sha_of "$cred")" = "$keep_sha" ] && [ "$(cat "$state/db_hash")" = "$keep_hash" ]; then
    pass "an account that is not a student is never managed (start)"
else fail "non-student on start (status=$status)"; fi
run -- --reset
if [ "$status" -eq 1 ] && has "not a student account" && [ "$(cat "$state/db_hash")" = "$keep_hash" ] && ! called "--password-only"; then
    pass "an account that is not a student never receives a new password (reset)"
else fail "non-student on reset (status=$status)"; fi

new_world; run --; echo 0 > "$state/db_active"; keep_sha=$(sha_of "$cred")
run --
if [ "$status" -eq 0 ] && has "deactivated" && [ "$(sha_of "$cred")" = "$keep_sha" ] && [ "$(cat "$state/db_active")" = 0 ]; then
    pass "a deactivated demo account is reported and not reactivated"
else fail "inactive account (status=$status)"; fi

# ------------------------------------------------------------ usage, and nothing secret in any output
new_world; run -- --frobnicate
if [ "$status" -eq 2 ] && has "Usage:" && [ ! -s "$state/calls" ]; then pass "an unknown argument is a usage error before any container call"
else fail "usage (status=$status)"; fi

leaked=0
while IFS= read -r secret; do
    [ -n "$secret" ] && grep -qF -- "$secret" "$work/all-output" && leaked=1
done < "$work/every-secret"
generated=$(wc -l < "$work/every-secret" | tr -d ' ')
if [ "$generated" -lt 10 ]; then out="(only $generated generated passwords were recorded)"; fail "the leak check knows the generated passwords"; fi
if grep -q 'Other-[0-9]*_[0-9]*-abcdefgh' "$work/all-output" || [ "$leaked" = 1 ]; then out="(a test password was printed)"; fail "no password appears in any output"
else pass "no password appears in any output"; fi
if grep -q 'fake\$[0-9a-f]\{64\}' "$work/all-output"; then out="(a hash was printed)"; fail "no password hash appears in any output"
else pass "no password hash appears in any output"; fi

echo "Demo credential bootstrap tests: $passed passed, $failed failed."
[ "$failed" -eq 0 ]
