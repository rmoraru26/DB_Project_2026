#!/usr/bin/env bash
# Runs the plugin's tests against another MariaDB server version.
#
#   make test-server-version MARIADB_IMAGE=mariadb:11.8@sha256:<digest>
#   bash scripts/test_server_version.sh mariadb:11.8@sha256:<digest>
#
# The project's server image is normally built FROM MariaDB 13.0.2 (audit API
# 0x0303).  This script builds the same Dockerfile FROM the given official
# image instead, so the plugin is compiled against that version's headers
# (the build also runs the plugin's unit tests), then:
#
#   1. starts a throw-away server from it and runs tests/plugin/run_plugin_tests.sh
#      (with the CHANGE_USER / prepared-statement helper) from a throw-away
#      test-runner container on a private network;
#   2. runs tests/plugin/test_thread_pool.sh and tests/plugin/test_stalled_log.sh
#      against the same image.
#
# Nothing of the running stack (make up) is used or changed.  Passwords are
# random, exist only in the throw-away containers and are never printed.  The
# containers and the network are removed at the end; the two images stay,
# tagged campus-audit-*:server-<tag>.  CI runs this for MariaDB 11.8.9
# (.github/workflows/ci.yml, job "server-11-8").  Exit status 0 when every
# check passed.
set -u
cd "$(dirname "$0")/.."
IMAGE=${1:-${MARIADB_IMAGE:-}}
if [ -z "$IMAGE" ]; then
    echo "usage: $0 <official MariaDB image, e.g. mariadb:11.8@sha256:...>" >&2
    exit 2
fi
export MSYS_NO_PATHCONV=1

tag=$(printf '%s' "$IMAGE" | sed -e 's/@.*//' -e 's/^[^:]*://' -e 's/[^A-Za-z0-9_.-]/-/g')
[ -n "$tag" ] || tag=custom
SERVER_IMAGE=campus-audit-mariadb:server-$tag
RUNNER_IMAGE=campus-audit-test-runner:server-$tag
ID=campus-audit-server-$tag-$$
NET=$ID-net; DB=$ID-db; RUN=$ID-runner

random_hex() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
ROOT_PW="r$(random_hex)"; APP_PW="a$(random_hex)"
cleanup() {
    docker rm -f -v "$DB" "$RUN" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== building the server and test-runner images FROM $IMAGE"
docker build --build-arg MARIADB_IMAGE="$IMAGE" -f docker/mariadb/Dockerfile -t "$SERVER_IMAGE" . || exit 3
docker build --build-arg MARIADB_IMAGE="$IMAGE" -f docker/mariadb/Dockerfile --target test-runner \
    -t "$RUNNER_IMAGE" . || exit 3

echo "== starting a throw-away server"
docker network create "$NET" >/dev/null || exit 2
docker run -d --name "$DB" --network "$NET" \
    -e MARIADB_ROOT_PASSWORD="$ROOT_PW" -e CAMPUS_APP_PASSWORD="$APP_PW" "$SERVER_IMAGE" >/dev/null || exit 2
# During initialisation the image runs a temporary server without networking;
# a TCP login succeeds only once the final server is up.
ready=0
for _ in $(seq 1 180); do
    if [ "$(docker exec -e MYSQL_PWD="$ROOT_PW" "$DB" mariadb -uroot -h127.0.0.1 --protocol=tcp \
              --batch --skip-column-names -e \
              "SELECT COUNT(*) FROM university_resources.users WHERE email = 'alice.student@example.edu'" \
              2>/dev/null | tr -d '\r')" = 1 ]; then
        ready=1; break
    fi
    sleep 1
done
[ "$ready" = 1 ] || { echo "FAIL: the throw-away server did not become ready"; docker logs "$DB" 2>&1 | tail -n 30; exit 1; }
docker exec -e MYSQL_PWD="$ROOT_PW" "$DB" mariadb -uroot -e "INSTALL SONAME 'campus_audit';" || exit 3

echo "== tests/plugin/run_plugin_tests.sh"
docker run -d --name "$RUN" --network "$NET" --entrypoint sleep "$RUNNER_IMAGE" infinity >/dev/null || exit 2
docker exec -e MYSQL_PWD="$ROOT_PW" -e DB="$DB" "$RUN" bash -c '
    cd /workspace
    export MARIADB_CLIENT="mariadb --skip-ssl --disable-ssl-verify-server-cert -h$DB -P3306" DB_ADMIN_USER=root
    export AUDIT_TEST_DIR=/var/log/campus_audit/ CHANGE_USER_CLIENT=/usr/local/bin/campus_change_user
    export CU_HOST=$DB CU_PORT=3306
    bash tests/plugin/run_plugin_tests.sh'
harness=$?

echo "== tests/plugin/test_thread_pool.sh"
THREAD_POOL_IMAGE="$SERVER_IMAGE" bash tests/plugin/test_thread_pool.sh
pool=$?

echo "== tests/plugin/test_stalled_log.sh"
STALL_TEST_IMAGE="$SERVER_IMAGE" bash tests/plugin/test_stalled_log.sh
stall=$?

echo "== result for $IMAGE: run_plugin_tests.sh exit $harness, test_thread_pool.sh exit $pool, test_stalled_log.sh exit $stall"
[ "$harness" = 0 ] && [ "$pool" = 0 ] && [ "$stall" = 0 ]
