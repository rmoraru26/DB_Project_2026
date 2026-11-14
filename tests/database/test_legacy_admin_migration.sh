#!/usr/bin/env bash
# Exercises migration 004 against a simulated legacy seeded admin in a
# transaction, then rolls every table change back.  It also re-runs
# database/seed.sql after the migration: the seed must not promote the
# demoted shared account again, nor change a locally promoted administrator
# (a seeded identity promoted after setup, and a non-seed administrator).
# seed.sql's own START TRANSACTION / COMMIT lines are left out so that its
# statements stay inside this test's transaction and are rolled back too.
# Needs the seed users (alice/bob/dana @example.edu) to exist already.
set -eu
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
TEST_EMAIL="remediation.$$.admin@example.edu"
BOB=bob.student@example.edu
BEFORE=$(printf 'SELECT COUNT(*) FROM university_resources.users;\n' \
    | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names)
# CR is removed first: a Windows checkout may have CRLF line endings, and a
# COMMIT left in would end this test's transaction and keep its changes.
seed_in_transaction() { tr -d '\r' < database/seed.sql | sed -e '/^[[:space:]]*START TRANSACTION;[[:space:]]*$/d' -e '/^[[:space:]]*COMMIT;[[:space:]]*$/d'; }
if seed_in_transaction | grep -v '^[[:space:]]*--' | grep -q -i -E '\b(COMMIT|START TRANSACTION|BEGIN|ROLLBACK)\b'; then
    echo "FAIL: database/seed.sql has transaction control this test cannot remove; not running it" >&2
    exit 1
fi
STATE="SELECT CONCAT_WS(',', (SELECT role FROM university_resources.users WHERE email='dana.admin@example.edu'), (SELECT role FROM university_resources.users WHERE email='$BOB'), (SELECT COUNT(*) FROM university_resources.users WHERE email='$TEST_EMAIL'));"
START_STATE=$(printf '%s\n' "$STATE" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names | tr -d '\r')
fingerprint="SELECT GROUP_CONCAT(CONCAT_WS('|', user_id, full_name, email, password_hash, role, is_active, created_at, updated_at) ORDER BY user_id) FROM university_resources.users WHERE email IN ('$BOB', '$TEST_EMAIL')"

result=$(
    {
        printf "START TRANSACTION;\n"
        printf "INSERT INTO university_resources.users (full_name,email,password_hash,role) VALUES ('Migration Test','%s','not-a-login-hash','admin');\n" "$TEST_EMAIL"
        printf "UPDATE university_resources.users SET role='admin' WHERE email='%s';\n" "$BOB"
        printf "UPDATE university_resources.users SET role='admin' WHERE email='dana.admin@example.edu';\n"
        seed_in_transaction
        cat database/migrations/004_remove_shared_admin.sql
        cat database/migrations/004_remove_shared_admin.sql
        printf "SELECT CONCAT('dana demoted: ', role='student') FROM university_resources.users WHERE email='dana.admin@example.edu';\n"
        printf "SELECT CONCAT('unrelated admin kept: ', role='admin') FROM university_resources.users WHERE email='%s';\n" "$TEST_EMAIL"
        printf "SELECT CONCAT('user rows preserved: ', COUNT(*)=%s+1) FROM university_resources.users;\n" "$BEFORE"
        printf "SET @frantastic_before = (%s);\n" "$fingerprint"
        seed_in_transaction
        printf "SELECT CONCAT('dana still student after seed re-run: ', role='student') FROM university_resources.users WHERE email='dana.admin@example.edu';\n"
        printf "SELECT CONCAT('promoted seed user still admin after seed re-run: ', role='admin') FROM university_resources.users WHERE email='%s';\n" "$BOB"
        printf "SELECT CONCAT('local administrators unmodified by seed re-run: ', (%s) <=> @frantastic_before);\n" "$fingerprint"
        printf "ROLLBACK;\n"
    } | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names | tr -d '\r'
)

expected="dana demoted: 1
unrelated admin kept: 1
user rows preserved: 1
dana still student after seed re-run: 1
promoted seed user still admin after seed re-run: 1
local administrators unmodified by seed re-run: 1"
if [ "$result" != "$expected" ]; then
    echo "FAIL: migration 004 / seed re-run did not keep the expected roles:" >&2
    printf '%s\n' "$result" | grep -v ': 1$' | sed 's/^/      /' >&2
    exit 1
fi
restored=$(printf '%s\n' "$STATE" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names | tr -d '\r')
if [ -z "$START_STATE" ] || [ "$restored" != "$START_STATE" ]; then
    echo "FAIL: rollback did not restore the starting database state" >&2
    exit 1
fi
echo "PASS: legacy admin demoted; unrelated admin and user rows preserved; rerun idempotent; transaction rolled back"
echo "PASS: seed re-run after migration 004 keeps the shared account a student and leaves local administrators unchanged"
