#!/usr/bin/env bash
# MariaDB-side operator wrapper for migration 007's demo-student procedures.
# Runs inside the mariadb container as root: the password comes from MYSQL_PWD
# (Linux `make`) or the service's MARIADB_ROOT_PASSWORD (scripts/mariadb_admin_auth.sh).
#
#   provision_local_demo_db.sh state       prints "<role> <is_active>" or "MISSING -"
#   provision_local_demo_db.sh bootstrap   FRANTASTIC_DEMO_HASH=<werkzeug hash>; prints CREATED or EXISTS
#   provision_local_demo_db.sh rotate      FRANTASTIC_DEMO_HASH=<werkzeug hash>; prints ROTATED, MISSING or NOT_STUDENT
#
# Only a hash ever reaches this script, never the password.  The hash is
# validated here (no quote, backslash or whitespace can pass) before it is
# placed into the CALL statement, and again by the procedures themselves.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mariadb_admin_auth.sh"
action=${1:-}
hash=${FRANTASTIC_DEMO_HASH:-}
pattern='^(scrypt|pbkdf2):[A-Za-z0-9:._$-]+$'
# Validate the request first (no credential needed for that), then require the
# root password before the first client call.
if [[ "$action" != state && "$action" != bootstrap && "$action" != rotate ]]; then
    echo "usage: provision_local_demo_db.sh state|bootstrap|rotate" >&2
    exit 2
fi
if [[ "$action" != state && ! "$hash" =~ $pattern ]]; then
    echo "A valid generated password hash is required." >&2
    exit 2
fi
frantastic_require_admin_password root provision_local_demo_db || exit 2
case "$action" in
  state) query="SELECT COALESCE((SELECT CONCAT(role, ' ', is_active) FROM university_resources.users WHERE email='demo.student@frantastic.local' LIMIT 1), 'MISSING -');" ;;
  bootstrap) query="CALL university_resources.bootstrap_local_demo_student('${hash}');" ;;
  rotate) query="CALL university_resources.rotate_local_demo_student('${hash}');" ;;
esac
printf '%s\n' "$query" | mariadb -uroot --batch --skip-column-names
