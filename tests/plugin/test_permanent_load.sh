#!/usr/bin/env bash
# Experiment 34 as a test: campus_audit loaded at server start as
# FORCE_PLUS_PERMANENT cannot be unloaded, and what is left to an
# administrator (narrowing it with SET GLOBAL) is recorded.
#
#   make test-permanent-load
#   bash tests/plugin/test_permanent_load.sh
#
# Builds the plugin-server image of docker/mariadb/Dockerfile (the one of
# make plugin-lab) and starts a throw-away server from it with
#   --plugin-load-add=campus_audit.so --campus-audit=FORCE_PLUS_PERMANENT
# No port is published; the root password is random and never printed; the
# container is removed at the end.  Exit status 0 when every check passed.
set -u
cd "$(dirname "$0")/../.."
export MSYS_NO_PATHCONV=1
IMAGE=campus-audit-plugin-lab:13.0.2
NAME=campus-audit-permanent-$$
PASS=0; FAIL=0
cleanup() { docker rm -f -v "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

docker build -q -f docker/mariadb/Dockerfile --target plugin-server -t "$IMAGE" . >/dev/null || exit 3
MARIADB_ROOT_PASSWORD="r$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export MARIADB_ROOT_PASSWORD
echo "== server options: --plugin-load-add=campus_audit.so --campus-audit=FORCE_PLUS_PERMANENT"
docker run -d --name "$NAME" -e MARIADB_ROOT_PASSWORD "$IMAGE" \
    --plugin-load-add=campus_audit.so --campus-audit=FORCE_PLUS_PERMANENT >/dev/null || exit 2
unset MARIADB_ROOT_PASSWORD

# Everything below runs inside the container (its root password is there).
inside() { docker exec -i "$NAME" bash -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch --skip-column-names "$@"' _ "$@"; }
ready=0
for _ in $(seq 1 120); do
    if docker exec "$NAME" bash -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -h127.0.0.1 --protocol=tcp -e "SELECT 1"' >/dev/null 2>&1; then
        ready=1; break
    fi
    sleep 1
done
[ "$ready" = 1 ] || { echo "FAIL: the server did not become ready"; docker logs "$NAME" 2>&1 | tail -n 20; exit 1; }

check() {  # check <description> <actual> <expected substring>
    case "$2" in
        *"$3"*) PASS=$((PASS + 1)); echo "PASS: $1" ;;
        *) FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "      expected '$3', got: $2" ;;
    esac
}
check "loaded with LOAD_OPTION FORCE_PLUS_PERMANENT and ACTIVE" \
    "$(printf '%s\n' "SELECT CONCAT(LOAD_OPTION, ' ', PLUGIN_STATUS) FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';" | inside 2>&1)" \
    "FORCE_PLUS_PERMANENT ACTIVE"
check "UNINSTALL SONAME is refused (ER 1702)" \
    "$(printf '%s\n' "UNINSTALL SONAME 'campus_audit';" | inside 2>&1)" "ERROR 1702"
check "UNINSTALL PLUGIN is refused (ER 1702)" \
    "$(printf '%s\n' "UNINSTALL PLUGIN campus_audit;" | inside 2>&1)" "ERROR 1702"
check "the plugin is still ACTIVE" \
    "$(printf '%s\n' "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';" | inside 2>&1)" \
    "ACTIVE"
printf '%s\n' "SET GLOBAL campus_audit_databases = 'nothing_here';" | inside >/dev/null 2>&1
log=$(docker exec "$NAME" cat /var/log/campus_audit/campus_audit.jsonl)
check "narrowing it with SET GLOBAL is recorded" \
    "$(printf '%s\n' "$log" | grep '"event":"config_change"' | grep '"variable":"campus_audit_databases"')" \
    '"value":"nothing_here"'
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
