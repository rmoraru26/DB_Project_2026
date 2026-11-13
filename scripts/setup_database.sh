#!/usr/bin/env bash
# Creates (or updates) the project databases on an existing MariaDB server and,
# if CAMPUS_APP_PASSWORD is set, the application account.
#
# ADMINISTRATOR ACCESS: needs an account that may create databases, triggers
# and users.  Every step is idempotent, so the script can be re-run.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" DB_ADMIN_USER=root MYSQL_PWD=... \
#       bash scripts/setup_database.sh
#
# Order (explicit, not the lexical order of database/migrations/):
#   1. schema.sql, migrations 001-003, triggers.sql   (SCHEMA_STEPS)
#   2. seed.sql                                       (skipped with SKIP_SEED=1)
#   3. migrations 004, 005, 006                       (POST_SEED_STEPS)
#   4. application account campus_app                 (if CAMPUS_APP_PASSWORD is set)
# On a fresh database seed.sql inserts the demo account dana.admin@example.edu
# as an administrator.  Migration 004 demotes it and migration 005 opens the
# one-time local administrator gate only when no administrator is left, so
# both must run after the seed: before it, 004 would find no Dana to demote,
# the seed would then leave a shared administrator behind, and 005 would have
# judged the gate before that administrator existed.  The seed sets a role
# only on insert, so re-running it never
# changes an existing user's role.  triggers.sql runs before the seed so that
# the seed rows and the demotion are recorded in audit_events.
#
# SKIP_SEED=1 leaves out seed.sql: used by scripts/post_start.sh (and
# `make migrate`) when it upgrades an existing database, whose data must not
# be touched.  Steps 1, 3 and 4 still run.
#
# The Docker setup runs the same files in the same order through
# /docker-entrypoint-initdb.d/ (docker/mariadb/Dockerfile) when it initialises
# an empty volume; scripts/check_repo.py checks that both orders agree.  A new
# migration must be added to one of the two lists below; the script refuses
# to run while a file in database/migrations/ is missing from them.

set -eu

cd "$(dirname "$0")/.."
CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}

SCHEMA_STEPS=(
    database/schema.sql
    database/migrations/001_audit_events_trigger_ownership.sql
    database/migrations/002_campus_audit_schema.sql
    database/migrations/003_audit_lab.sql
    database/triggers.sql
)
SEED_STEP=database/seed.sql
POST_SEED_STEPS=(
    database/migrations/004_remove_shared_admin.sql
    database/migrations/005_local_admin_bootstrap_state.sql
    database/migrations/006_cancelled_loan_status.sql
)

listed=" ${SCHEMA_STEPS[*]} ${POST_SEED_STEPS[*]} "
for migration in database/migrations/[0-9]*.sql; do
    case "$listed" in
        *" $migration "*) ;;
        *) echo "setup_database.sh: $migration is not in SCHEMA_STEPS or POST_SEED_STEPS; add it there" >&2
           exit 1 ;;
    esac
done

run() {
    echo "-> $1"
    "${CLIENT[@]}" -u"$ADMIN_USER" --batch < "$1"
}

for step in "${SCHEMA_STEPS[@]}"; do
    run "$step"
done
if [ "${SKIP_SEED:-}" = "1" ]; then
    echo "(SKIP_SEED=1: seed.sql not loaded)"
else
    run "$SEED_STEP"
fi
for step in "${POST_SEED_STEPS[@]}"; do
    run "$step"
done

if [ -n "${CAMPUS_APP_PASSWORD:-}" ]; then
    echo "-> application account campus_app"
    bash database/app_account.sh | "${CLIENT[@]}" -u"$ADMIN_USER" --batch
else
    echo "(CAMPUS_APP_PASSWORD not set: application account not created)"
fi
echo "Database setup complete."
