#!/usr/bin/env bash
# Static checks of the database installation scripts; no database server.
#
#   1. scripts/setup_database.sh applies its files in the documented order for a
#      fresh install and for an upgrade (SKIP_SEED=1), using a stub client that
#      only reads its input;
#   2. it refuses to run while a migration is missing from its order;
#   3. docker/mariadb/Dockerfile initialises a volume in the same order and runs
#      the application-account script last;
#   4. database/app_account.sh prints the intended least-privilege grants.
#
#   bash tests/shell/test_database_setup.sh
#
# Everything runs in a temporary copy of the files involved; the working tree
# is not changed.  The application password used here is random and is never
# printed.

set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree/scripts"
cp -R "$ROOT/database" "$work/tree/database"
cp "$ROOT/scripts/setup_database.sh" "$work/tree/scripts/"
# Stub client: consumes the SQL it is given and does nothing else.
printf '#!/usr/bin/env bash\ncat > /dev/null\n' > "$work/fake_mariadb"

random_password() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

setup_steps() {   # setup_steps [VAR=value ...]: the "-> " lines of one run
    env -u CAMPUS_APP_PASSWORD "$@" MARIADB_CLIENT="bash $work/fake_mariadb" \
        bash "$work/tree/scripts/setup_database.sh" 2>&1 | tr -d '\r' | sed -n 's/^-> //p'
}

fresh_expected="database/schema.sql
database/migrations/001_audit_events_trigger_ownership.sql
database/migrations/002_campus_audit_schema.sql
database/migrations/003_audit_lab.sql
database/triggers.sql
database/seed.sql
database/migrations/004_remove_shared_admin.sql
database/migrations/005_local_admin_bootstrap_state.sql
database/migrations/006_cancelled_loan_status.sql
application account campus_app"
upgrade_expected=$(printf '%s\n' "$fresh_expected" | grep -v -x 'database/seed.sql')

pw=$(random_password)
got=$(setup_steps CAMPUS_APP_PASSWORD="$pw")
if [ "$got" = "$fresh_expected" ]; then pass "fresh install order: schema, 001-003, triggers, seed, 004-006, account"
else fail "fresh install order" "got: $(printf '%s' "$got" | tr '\n' ' ')"; fi

got=$(setup_steps SKIP_SEED=1 CAMPUS_APP_PASSWORD="$pw")
if [ "$got" = "$upgrade_expected" ]; then pass "upgrade order (SKIP_SEED=1): seed skipped, 004-006 still run, account refreshed"
else fail "upgrade order (SKIP_SEED=1)" "got: $(printf '%s' "$got" | tr '\n' ' ')"; fi

got=$(setup_steps SKIP_SEED=1)
expected=$(printf '%s\n' "$upgrade_expected" | grep -v -x 'application account campus_app')
if [ "$got" = "$expected" ]; then pass "without CAMPUS_APP_PASSWORD the account step is skipped"
else fail "without CAMPUS_APP_PASSWORD the account step is skipped" "got: $(printf '%s' "$got" | tr '\n' ' ')"; fi

# A migration that is not in the explicit order must stop the script before
# anything is applied.
printf 'SELECT 1;\n' > "$work/tree/database/migrations/999_unlisted.sql"
out=$(env -u CAMPUS_APP_PASSWORD MARIADB_CLIENT="bash $work/fake_mariadb" \
      bash "$work/tree/scripts/setup_database.sh" 2>&1); status=$?
if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -q '999_unlisted.sql' && ! printf '%s' "$out" | grep -q '^-> '; then
    pass "an unlisted migration stops setup_database.sh before any step runs"
else
    fail "an unlisted migration stops setup_database.sh before any step runs" "exit $status: $out"
fi
rm -f "$work/tree/database/migrations/999_unlisted.sql"

# Docker initdb order: COPY destinations in /docker-entrypoint-initdb.d/ sorted
# by file name, as the official entrypoint runs them.
docker_order=$(tr -d '\r' < docker/mariadb/Dockerfile \
    | awk '$1 == "COPY" && NF == 3 && $3 ~ /^\/docker-entrypoint-initdb\.d\// { n = $3; sub(/.*\//, "", n); print n, $2 }' \
    | LC_ALL=C sort | awk '{ print $2 }')
docker_sql=$(printf '%s\n' "$docker_order" | grep '\.sql$')
fresh_sql=$(printf '%s\n' "$fresh_expected" | grep '\.sql$')
if [ "$docker_sql" = "$fresh_sql" ]; then pass "Dockerfile initdb SQL order equals setup_database.sh"
else fail "Dockerfile initdb SQL order equals setup_database.sh" "got: $(printf '%s' "$docker_sql" | tr '\n' ' ')"; fi
if [ "$(printf '%s\n' "$docker_order" | tail -n 1)" = "docker/mariadb/initdb/50-app-account.sh" ]; then
    pass "Dockerfile runs the application-account script after every SQL step"
else
    fail "Dockerfile runs the application-account script after every SQL step"
fi

# seed.sql must not assign a role to an existing user: a re-run after
# migration 004 would otherwise promote the shared demo account again or
# demote a locally assigned administrator.  The role is set only on insert.
users_insert=$(tr -d '\r' < database/seed.sql | grep -v '^[[:space:]]*--' \
    | awk '/INSERT INTO users/ { on = 1 } on { print } on && /;/ { exit }')
users_update=$(printf '%s\n' "$users_insert" | sed -n '/ON DUPLICATE KEY UPDATE/,$p')
if printf '%s\n' "$users_insert" | grep -q "'dana.admin@example.edu'.*'admin'" \
   && [ -n "$users_update" ] && ! printf '%s\n' "$users_update" | grep -q -i -E '\brole\b|is_active'; then
    pass "seed.sql: users ON DUPLICATE KEY UPDATE never changes role (Dana is admin only on first insert)"
else
    fail "seed.sql: users ON DUPLICATE KEY UPDATE never changes role" "$users_update"
fi

# Grants printed by database/app_account.sh.
sql=$(CAMPUS_APP_PASSWORD="$pw" bash database/app_account.sh | tr -d '\r')
if printf '%s' "$sql" | grep -q -F "$pw"; then fail "the plain password does not appear in the account SQL"
else pass "the plain password does not appear in the account SQL"; fi
grants=$(printf '%s\n' "$sql" | grep '^GRANT ')
expect_grant() {
    if printf '%s\n' "$grants" | grep -q -x -F "$1"; then pass "grant: $1"; else fail "grant: $1"; fi
}
acct="'campus_app'@'%'"
expect_grant "GRANT SELECT ON university_resources.users TO $acct;"
expect_grant "GRANT INSERT (full_name, email, password_hash) ON university_resources.users TO $acct;"
expect_grant "GRANT UPDATE (full_name, password_hash) ON university_resources.users TO $acct;"
expect_grant "GRANT SELECT, INSERT, UPDATE ON university_resources.loans TO $acct;"
expect_grant "GRANT SELECT, INSERT, UPDATE, DELETE ON university_resources.audit_lab_notes TO $acct;"
expect_grant "GRANT EXECUTE ON PROCEDURE campus_audit.import_current_log TO $acct;"
users_grants=$(printf '%s\n' "$grants" | grep 'university_resources\.users ')
if printf '%s\n' "$users_grants" | grep -q -E 'role|is_active|ALL|GRANT (INSERT|UPDATE)[, ]*ON|GRANT [A-Z, ]*(INSERT|UPDATE|DELETE)[A-Z, ]* ON'; then
    fail "users: no role/is_active write and no table-wide INSERT/UPDATE/DELETE" "$users_grants"
else
    pass "users: no role/is_active write and no table-wide INSERT/UPDATE/DELETE"
fi
if printf '%s\n' "$grants" | grep -E 'DELETE' | grep -v -q 'audit_lab_notes'; then
    fail "DELETE is granted only on audit_lab_notes" "$(printf '%s\n' "$grants" | grep DELETE)"
else
    pass "DELETE is granted only on audit_lab_notes"
fi
if printf '%s\n' "$grants" | grep -E 'audit_events|plugin_events|campus_audit\.\*' | grep -q -E 'INSERT|UPDATE|DELETE|ALL'; then
    fail "audit tables are read-only for the application"
else
    pass "audit tables are read-only for the application"
fi
if printf '%s\n' "$grants" | grep -q -E 'FILE|SUPER|ALL PRIVILEGES|\*\.\*'; then
    fail "no FILE, SUPER or global privilege"
else
    pass "no FILE, SUPER or global privilege"
fi
# The old table-wide grants are revoked before the column grants are applied,
# and only TABLE_PRIVILEGES is consulted, so the column grants survive re-runs.
revoke_line=$(printf '%s\n' "$sql" | grep -n 'FROM information_schema.TABLE_PRIVILEGES' | cut -d: -f1)
grant_line=$(printf '%s\n' "$sql" | grep -n '^GRANT UPDATE (full_name, password_hash)' | cut -d: -f1)
if [ -n "$revoke_line" ] && [ -n "$grant_line" ] && [ "$revoke_line" -lt "$grant_line" ] \
   && ! printf '%s\n' "$sql" | grep -v '^--' | grep -q 'COLUMN_PRIVILEGES'; then
    pass "table-wide users grants are revoked before, and without touching, the column grants"
else
    fail "table-wide users grants are revoked before, and without touching, the column grants"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
