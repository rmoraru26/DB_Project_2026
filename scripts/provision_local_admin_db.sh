#!/usr/bin/env bash
# MariaDB-side operator wrapper for migration 005's guarded procedures.
# Runs inside the mariadb container as root: the password comes from MYSQL_PWD
# (Linux `make`) or the service's MARIADB_ROOT_PASSWORD (scripts/mariadb_admin_auth.sh).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mariadb_admin_auth.sh"
action=${1:-}
hash=${FRANTASTIC_ADMIN_HASH:-}
pattern='^(scrypt|pbkdf2):[A-Za-z0-9:._$-]+$'
# Validate the request first (no credential needed for that), then require the
# root password before the first client call.
if [[ "$action" != state && "$action" != bootstrap && "$action" != bootstrap-force && "$action" != rotate ]]; then
    echo "usage: provision_local_admin_db.sh state|bootstrap|bootstrap-force|rotate" >&2
    exit 2
fi
if [[ "$action" != state && ! "$hash" =~ $pattern ]]; then
    echo "A valid generated password hash is required." >&2
    exit 2
fi
frantastic_require_admin_password root provision_local_admin_db || exit 2
if [[ "$action" == state ]]; then
    mariadb -uroot --batch --skip-column-names -e \
      "SELECT s.bootstrap_pending, (SELECT COUNT(*) FROM university_resources.users WHERE role='admin'), COALESCE((SELECT role FROM university_resources.users WHERE email='admin@frantastic.local' LIMIT 1),'MISSING') FROM university_resources.local_admin_bootstrap_state AS s WHERE s.singleton=1;"
    exit
fi
case "$action" in
  bootstrap) query="CALL university_resources.bootstrap_local_admin('${hash}', FALSE);" ;;
  bootstrap-force) query="CALL university_resources.bootstrap_local_admin('${hash}', TRUE);" ;;
  rotate) query="CALL university_resources.rotate_local_admin('${hash}');" ;;
esac
printf '%s\n' "$query" | mariadb -uroot --batch --skip-column-names
