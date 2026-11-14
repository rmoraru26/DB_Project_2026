#!/usr/bin/env bash
# Sets the passwords stored in an EXISTING database volume to the ones in
# .env, without deleting anything.  Run it through `make repair-credentials`.
#
# Why it is needed: the MariaDB image applies MARIADB_ROOT_PASSWORD, and runs
# docker/mariadb/initdb/ (which creates campus_app), only when it initialises
# an EMPTY volume.  A new .env (fresh clone, deleted .env, make_env.sh run
# again) changes neither password inside a volume that already exists: the
# volume name is fixed by compose.yaml (name: campus-audit), so even a clone
# in another directory reuses it.  Then root logins fail with ERROR 1045
# (make demo, make test) and the web app cannot log in as campus_app.
#
# How: stop the stack; start a one-off server on the same volume with
# --skip-grant-tables --skip-networking (reachable only through its socket,
# inside that throwaway container); ALTER USER root and campus_app to the
# hashes of the .env passwords; shut it down.  The hashes are computed here
# (database/native_password_hash.sh) and passed by environment-variable name,
# so neither a password nor a hash appears on a command line.  Databases,
# the audit-log volume and the plugin installation are kept.
#
#   YES=1 bash scripts/repair_credentials.sh     (no confirmation prompt)

set -eu

cd "$(dirname "$0")/.."
COMPOSE=(${COMPOSE:-docker compose})

[ -f .env ] || { echo "repair_credentials: .env not found; run make_env.sh or restore it" >&2; exit 1; }
set -a; . ./.env; set +a
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD missing in .env}"
: "${CAMPUS_APP_PASSWORD:?CAMPUS_APP_PASSWORD missing in .env}"

if [ "${YES:-}" != "1" ]; then
    printf '%s\n' "This stops the containers and sets the root and campus_app passwords stored in" \
                  "the database volume to the values in .env. No data is deleted."
    printf 'Continue? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing changed."; exit 1 ;; esac
fi

REPAIR_ROOT_HASH=$(printf '%s' "$MARIADB_ROOT_PASSWORD" | bash database/native_password_hash.sh)
REPAIR_APP_HASH=$(printf '%s' "$CAMPUS_APP_PASSWORD" | bash database/native_password_hash.sh)
export REPAIR_ROOT_HASH REPAIR_APP_HASH

"${COMPOSE[@]}" stop web mariadb

"${COMPOSE[@]}" run --rm --no-deps -T -e REPAIR_ROOT_HASH -e REPAIR_APP_HASH \
    --entrypoint bash mariadb -s <<'IN_CONTAINER'
set -eu
for h in "$REPAIR_ROOT_HASH" "$REPAIR_APP_HASH"; do
    printf '%s' "$h" | grep -Eq '^\*[0-9A-F]{40}$' || { echo "repair: unexpected hash format" >&2; exit 1; }
done
mariadbd --user=mysql --skip-grant-tables --skip-networking --log-error=/tmp/repair.err &
pid=$!
for _ in $(seq 1 60); do
    mariadb-admin --silent ping >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || { echo "repair: server did not start" >&2; tail -n 20 /tmp/repair.err >&2; exit 1; }
    sleep 1
done
mariadb -uroot --batch <<SQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY PASSWORD '$REPAIR_ROOT_HASH';
ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY PASSWORD '$REPAIR_ROOT_HASH';
ALTER USER IF EXISTS 'campus_app'@'%' IDENTIFIED BY PASSWORD '$REPAIR_APP_HASH';
SQL
kill "$pid"
wait "$pid" || true
echo "repair: stored passwords of root and campus_app now match .env"
IN_CONTAINER

echo "Done. Start the stack again with: make up"
