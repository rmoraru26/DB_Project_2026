#!/usr/bin/env bash
# Final verification (adapted from the Phase 1 driver) on a Linux host (container with Docker CLI + GNU
# make talking to Docker Desktop's engine).  Fresh tree, fresh volumes.
# Every step's complete output goes to $OUT/NN-name.txt; this script prints
# one summary line per step.  Stage selection: final_regression.sh <stage>.
set -u
SRC=/work/final
OUT=/work/out
PROJECT=frt-final-28f2fc09
mkdir -p "$OUT"
cd "$SRC" || exit 2
step() {   # step <file> <description> <command...>
    local file=$1 what=$2; shift 2
    {
        echo "# $what"
        echo "# command: $*"
        echo "# started: $(date -u +%FT%TZ)   host: $(uname -srm), GNU make $(make --version | sed -n 1p | awk '{print $3}'), $(docker --version), compose $(docker compose version --short)"
        echo
        "$@" 2>&1
        status=$?
        echo
        echo "# exit status: $status"
    } > "$OUT/$file.txt" < /dev/null
    printf '%-34s %s\n' "$file" "$(grep '^# exit status' "$OUT/$file.txt")"
}
project_env() {   # the isolation settings every .env of this run needs
    printf 'COMPOSE_PROJECT_NAME=%s\nCOMPOSE_FILE=compose.yaml:compose.final.yaml\n' "$PROJECT" >> .env
    sed -i -e 's/^MARIADB_PORT=.*/MARIADB_PORT=27307/' -e 's/^WEB_PORT=.*/WEB_PORT=27080/' .env
}
login() { { IFS= read -r E; IFS= read -r P; } < "$1"; LOGIN_EMAIL=$E LOGIN_PASSWORD=$P docker compose exec -T -e LOGIN_EMAIL -e LOGIN_PASSWORD web python - < tests/integration/http_login.py; }
rootsql() { ( set -a; . ./.env; set +a; MYSQL_PWD=$MARIADB_ROOT_PASSWORD docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot --batch --skip-column-names -e "$1" ); }

case "${1:-}" in
prepare)
    bash scripts/make_env.sh > "$OUT/00-make-env.txt" 2>&1
    project_env
    cat > compose.final.yaml <<EOF
# Test-only override: private image names for the final verification run (tree 28f2fc09).
services:
  mariadb:
    image: $PROJECT-mariadb:13.0.2
  web:
    image: $PROJECT-web
  test-runner:
    image: $PROJECT-test-runner
EOF
    docker compose --profile test config --format json | python3 -c "import json,sys; c=json.load(sys.stdin); print('project:', c['name']); print('volumes:', [v['name'] for v in c['volumes'].values()]); print('images:', sorted(d.get('image') for d in c['services'].values()))"
    ;;
static)
    step 01-unit-tests "Plugin unit tests, g++ on the Linux host" make -C plugin clean test
    step 02-shell-tests "Shell tests of the installation scripts (real Linux file system)" bash -c 'bash tests/shell/test_admin_auth.sh && bash tests/shell/test_demo_bootstrap.sh && bash tests/shell/test_database_setup.sh'
    step 03-repository-checks "Repository checks and source-distribution test" bash -c 'python3 scripts/check_repo.py && python3 tests/test_source_distribution.py'
    step 04-mutation-check "Mutation check of the plugin unit tests" python3 scripts/mutation_check.py -j 6
    ;;
fresh)
    step 10-make-up-fresh "Fresh installation: make up on an empty volume" make up
    step 11-make-doctor "make doctor" make doctor
    step 12-make-demo "make demo" make demo
    step 13-fresh-install-checks "What a fresh installation provides" bash -c '
        echo "credential files (mode owner bytes lines):"; for f in .env .demo-credentials .admin-credentials; do echo "  $f $(stat -c "%a %U %s" $f) $(wc -l < $f)"; done
        echo "first line of .demo-credentials: $(sed -n 1p .demo-credentials)"
        echo "pending or temporary credential files: $(ls -a | grep -c -E "credentials\.(pending|tmp)")"
        '
    { echo "# demo student over HTTP (tests/integration/http_login.py)"; login .demo-credentials; echo "# administrator over HTTP"; login .admin-credentials;
      echo "# catalogue"; rootsql "SELECT CONCAT(COUNT(*), ' catalogue items, ', COUNT(DISTINCT name), ' types') FROM university_resources.items WHERE asset_tag LIKE CONCAT(name, ' _'); SELECT CONCAT(COUNT(*), ' rooms in total: ', GROUP_CONCAT(name ORDER BY room_id SEPARATOR ', ')) FROM university_resources.rooms; SELECT CONCAT('accounts: ', GROUP_CONCAT(CONCAT(email, ' (', role, ')') ORDER BY user_id SEPARATOR ', ')) FROM university_resources.users; SELECT CONCAT('plugin: ', PLUGIN_STATUS, ' ', PLUGIN_AUTH_VERSION, ' ', PLUGIN_MATURITY, ' ', PLUGIN_LICENSE) FROM information_schema.PLUGINS WHERE PLUGIN_NAME=\"campus_audit\"; SELECT CONCAT('migrations: demo constraint ', COUNT(*)) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_NAME=\"chk_users_demo_is_student\";"
    } >> "$OUT/13-fresh-install-checks.txt" 2>&1
    tail -n 9 "$OUT/13-fresh-install-checks.txt"
    ;;
suites)
    step 20-make-test "make test: every suite in the test-runner container" make test
    step 21-make-examples "make examples" make examples
    step 22-make-test-integration "make test-integration: demo credential life cycle, log rotation, thread pool" env LIFECYCLE_LOG_DIR="$OUT/lifecycle" make test-integration
    step 23-make-test-app "make test-app (web container)" make test-app
    ;;
restart)
    step 30-restart "Restart of the database server, then make up and make doctor" bash -c 'before=$(sha256sum .demo-credentials .admin-credentials | sha256sum); docker compose restart mariadb && make up && make doctor && after=$(sha256sum .demo-credentials .admin-credentials | sha256sum) && [ "$before" = "$after" ] && echo "RESULT: both credential files unchanged after the restart"'
    { echo "# logins after the restart"; login .demo-credentials; login .admin-credentials; } >> "$OUT/30-restart.txt" 2>&1
    tail -n 3 "$OUT/30-restart.txt"
    ;;
recreate)
    # make reset deletes this project's volumes; the two credential files stay.
    step 31-volume-recreated "make reset (deletes the test volumes), then make up with the saved credential files" bash -c 'before=$(sha256sum .demo-credentials .admin-credentials | sha256sum); make reset && make up && after=$(sha256sum .demo-credentials .admin-credentials | sha256sum) && [ "$before" = "$after" ] && echo "RESULT: both credential files unchanged; the accounts were created in the new database with the saved passwords"'
    { echo "# logins against the re-created database"; login .demo-credentials; login .admin-credentials; rootsql "SELECT CONCAT(COUNT(*), ' catalogue items after re-creation') FROM university_resources.items WHERE asset_tag LIKE CONCAT(name, ' _');"; } >> "$OUT/31-volume-recreated.txt" 2>&1
    grep -E "saved local credential|reconciled|RESULT|login=|catalogue items" "$OUT/31-volume-recreated.txt"
    ;;
stale-env)
    # The CI regression: a new .env against an existing volume is explained and repaired without data loss.
    step 32-stale-env "New .env against an existing volume: refused, explained, repaired, data kept" bash -c '
        users_before=$(set -a; . ./.env; set +a; docker compose exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb mariadb -uroot -N -e "SELECT COUNT(*) FROM university_resources.users")
        mv .env .env.previous
        bash scripts/make_env.sh
        printf "COMPOSE_PROJECT_NAME=frt-final-28f2fc09\nCOMPOSE_FILE=compose.yaml:compose.final.yaml\n" >> .env
        sed -i -e "s/^MARIADB_PORT=.*/MARIADB_PORT=27307/" -e "s/^WEB_PORT=.*/WEB_PORT=27080/" .env
        if make up > /tmp/stale-up.txt 2>&1; then echo "FAIL: make up accepted the stale passwords"; exit 1; fi
        grep -q "rejects the root password" /tmp/stale-up.txt && echo "PASS: make up refused and explained the stale volume"
        if make doctor > /tmp/stale-doctor.txt 2>&1; then echo "FAIL: doctor did not report it"; exit 1; fi
        grep -q "ERROR 1045" /tmp/stale-doctor.txt && echo "PASS: make doctor names ERROR 1045"
        YES=1 make repair-credentials && make doctor || exit 1
        users_after=$(set -a; . ./.env; set +a; docker compose exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb mariadb -uroot -N -e "SELECT COUNT(*) FROM university_resources.users")
        [ "$users_before" = "$users_after" ] && echo "PASS: $users_after user rows before and after the repair"
        make test-app'
    grep -E "^PASS|^FAIL|passed|failed" "$OUT/32-stale-env.txt" | tail -n 6
    ;;
bench)
    step 40-benchmark "make bench: no plugin / campus_audit / server_audit, two passes" make bench
    tail -n 12 "$OUT/40-benchmark.txt"
    ;;
*) echo "usage: final_regression.sh prepare|static|fresh|suites|restart|recreate|stale-env|bench"; exit 2 ;;
esac
