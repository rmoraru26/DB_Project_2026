#!/usr/bin/env bash
# The plugin on its own: build campus_audit and the skeleton plugin against
# MariaDB 13.0.2, start a throw-away server that holds nothing else, and run
# the guided tour plugin/lab/tour.sh in it.
#
#   make plugin-lab                 build, start, tour (the container stays for experiments)
#   make plugin-lab-down            remove the container
#   bash scripts/plugin_lab.sh [--down]
#   Windows: .\frantastic.cmd plugin-lab / plugin-lab-down (the same docker commands)
#
# Uses the target plugin-server of docker/mariadb/Dockerfile: the project's
# server image without the booking schema, the triggers and the web
# application.  The image build compiles both plugins and runs the plugin's
# unit tests.  Nothing of `make up` is used or changed: no .env, no compose
# project, no volume, no published port.  The root password is random, reaches
# the container by variable name only and is never printed.
set -u
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
NAME=campus-audit-plugin-lab
IMAGE=campus-audit-plugin-lab:13.0.2

if [ "${1:-}" = "--down" ]; then
    docker rm -f -v "$NAME" >/dev/null 2>&1 && echo "removed $NAME" || echo "$NAME is not running"
    exit 0
fi

echo "== building $IMAGE (target plugin-server; compiles the plugins, runs the unit tests)"
docker build -f docker/mariadb/Dockerfile --target plugin-server -t "$IMAGE" . || exit 3

docker rm -f -v "$NAME" >/dev/null 2>&1
MARIADB_ROOT_PASSWORD="r$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export MARIADB_ROOT_PASSWORD
echo "== starting the throw-away server $NAME (no published port)"
docker run -d --name "$NAME" -e MARIADB_ROOT_PASSWORD "$IMAGE" >/dev/null || exit 2
unset MARIADB_ROOT_PASSWORD

docker cp plugin/lab/tour.sh "$NAME":/tmp/tour.sh >/dev/null || exit 2
docker exec "$NAME" bash /tmp/tour.sh
