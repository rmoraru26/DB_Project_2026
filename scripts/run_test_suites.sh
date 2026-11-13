#!/usr/bin/env bash
# Runtime test orchestrator shared by Linux `make test` and Windows `test`.
# This script executes tests on every invocation; Docker build layers only
# cache dependencies and binaries, never a previous test result.
set -u
cd /workspace

results=()
run_suite() {
    local name=$1; shift
    echo "== $name"
    "$@"
    local rc=$?
    if [ "$rc" -eq 0 ]; then results+=(PASS); echo "[PASS] $name"
    else results+=(FAIL); echo "[FAIL] $name (exit $rc)"; fi
}

run_suite "Plugin C++ unit tests" make -C plugin test
run_suite "Repository checks" bash -c 'python3 scripts/check_repo.py && python3 tests/test_source_distribution.py'
run_suite "Administrator credential and diagnostic tests" bash tests/shell/test_admin_auth.sh
run_suite "Database installation order and account SQL (no server)" bash tests/shell/test_database_setup.sh
# Container-to-container tests use the private Compose network, not a public
# endpoint. Disable TLS and its default certificate-verification policy so
# MariaDB 11.4+ does not emit a warning into the test scripts' SQL output.
export MARIADB_CLIENT="mariadb --skip-ssl --disable-ssl-verify-server-cert -h${DB_HOST:-mariadb} -P${DB_PORT:-3306}"
export DB_ADMIN_USER=root
export MYSQL_PWD=${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD is required for integration and database tests}
export AUDIT_TEST_DIR=/var/log/campus_audit/
export CHANGE_USER_CLIENT=/usr/local/bin/campus_change_user
export CU_HOST=${DB_HOST:-mariadb}
export CU_PORT=${DB_PORT:-3306}
run_suite "Plugin integration tests" bash tests/plugin/run_plugin_tests.sh
run_suite "Database tests" bash -c 'bash tests/database/test_legacy_admin_migration.sh && bash tests/database/test_cancelled_loan_migration.sh && bash tests/database/test_audit_triggers.sh && bash tests/database/test_app_account_grants.sh && bash tests/database/test_native_password_hash.sh && bash tests/database/run_database_tests.sh'

export RUN_DB_TESTS=1
export DB_USER=${APP_DB_USER:-campus_app}
export DB_PASSWORD=${CAMPUS_APP_PASSWORD:?CAMPUS_APP_PASSWORD is required for application tests}
export SECRET_KEY=${SECRET_KEY:?SECRET_KEY is required for application tests}
app_command=(/opt/frantastic-test-venv/bin/python -m pytest -q frontend/tests)
if [ -n "${TEST_ADMIN_EMAIL:-}" ] && [ -n "${TEST_ADMIN_PASSWORD:-}" ]; then export TEST_ADMIN_EMAIL TEST_ADMIN_PASSWORD; fi
run_suite "Application and Audit Lab tests" "${app_command[@]}"

passed=0; failed=0; skipped=0
for result in "${results[@]}"; do
    case "$result" in PASS) passed=$((passed + 1));; FAIL) failed=$((failed + 1));; SKIP) skipped=$((skipped + 1));; esac
done
echo ""
echo "Summary:"
echo "Total suites: ${#results[@]}"
echo "Passed: $passed"
echo "Failed: $failed"
echo "Skipped suites: $skipped"
echo "Individual pytest skips (if any) are listed in the application suite output above."
if [ "$failed" -eq 0 ]; then echo "Overall result: PASS"; exit 0; fi
echo "Overall result: FAIL"
exit 1
