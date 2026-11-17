#!/usr/bin/env bash
# Prints the SQL that creates (or updates) the web application's database account.
#
#   CAMPUS_APP_PASSWORD=... bash database/app_account.sh | mariadb -uroot -p
#   CAMPUS_APP_PASSWORD=... bash database/app_account.sh --password-only   # only ALTER USER IF EXISTS
#
# The password comes from the environment (see .env.example) and is never
# stored in the repository.  It does not appear in the printed SQL either:
# the account is created with IDENTIFIED BY PASSWORD '<hash>', where the hash
# is the mysql_native_password value computed by native_password_hash.sh
# ('*' + 40 hex digits).  The only other value placed into the SQL is the
# account's host, which must match [A-Za-z0-9.%_-]+.  The password rule below
# (12+ characters of A-Z a-z 0-9 . _ -) keeps it safe in .env and Compose files.
#
# Least privilege: the application may read rooms/items, register user
# profiles (but cannot choose or change roles), change only full_name and
# password_hash of an existing user (account settings; never role or
# is_active), create and change bookings and loans (a future loan is cancelled
# with status 'cancelled', migration 006, not deleted), and read the audit
# data for the admin page and the Audit Lab.  The only table it may DELETE from is the disposable
# audit_lab_notes (the lab's "delete" action).  It cannot write audit_events
# (the triggers run with their DEFINER's privileges) or campus_audit.plugin_events,
# and it has no FILE privilege: it may only EXECUTE import_current_log(),
# which imports the plugin's current log file with its definer's rights.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
pw=${CAMPUS_APP_PASSWORD:-}
host=${CAMPUS_APP_HOST:-%}

if [ -z "$pw" ]; then
    echo "app_account.sh: CAMPUS_APP_PASSWORD is not set" >&2
    exit 1
fi
if ! printf '%s' "$pw" | grep -Eq '^[A-Za-z0-9._-]{12,}$'; then
    echo "app_account.sh: CAMPUS_APP_PASSWORD must be 12+ characters of A-Z a-z 0-9 . _ -" >&2
    exit 1
fi
if ! printf '%s' "$host" | grep -Eq '^[A-Za-z0-9.%_-]+$'; then
    echo "app_account.sh: CAMPUS_APP_HOST contains unsupported characters" >&2
    exit 1
fi

hash=$(printf '%s' "$pw" | bash "$here/native_password_hash.sh")
account="'campus_app'@'$host'"
# Decoy for the Audit Lab's "failed database login": no privileges, locked,
# and a random hash whose password nobody knows.  It has to exist: for an
# unknown account MariaDB answers with an authentication-plugin switch (on
# 13.0.2 for Windows to auth_gssapi_client) instead of ER 1045, so PyMySQL
# aborts and the plugin records status 1158 rather than a plain failed login.
decoy_hash="*$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"

if [ "${1:-}" = "--password-only" ]; then
    echo "ALTER USER IF EXISTS $account IDENTIFIED BY PASSWORD '$hash';"
    exit 0
fi

cat <<SQL
CREATE USER IF NOT EXISTS $account IDENTIFIED BY PASSWORD '$hash';
ALTER USER $account IDENTIFIED BY PASSWORD '$hash';
-- MariaDB returns ER 1147 when revoking a grant that does not exist. On a
-- fresh account there is nothing to remove; on an upgraded account revoke
-- only the old table-level INSERT/UPDATE grants before applying the least-
-- privilege grants below. Identifiers are built from the validated host.
-- Only TABLE_PRIVILEGES (table-wide grants) is consulted, so the column-level
-- INSERT/UPDATE grants below (COLUMN_PRIVILEGES) survive every re-run.
SET @frantastic_app_account = CONCAT(QUOTE('campus_app'), '@', QUOTE('$host'));
SELECT GROUP_CONCAT(DISTINCT PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', ')
  INTO @frantastic_old_user_writes
  FROM information_schema.TABLE_PRIVILEGES
 WHERE GRANTEE = @frantastic_app_account
   AND TABLE_SCHEMA = 'university_resources'
   AND TABLE_NAME = 'users'
   AND PRIVILEGE_TYPE IN ('INSERT', 'UPDATE');
SET @frantastic_revoke_sql = IF(
    @frantastic_old_user_writes IS NULL,
    'DO 0',
    CONCAT('REVOKE ', @frantastic_old_user_writes,
           ' ON university_resources.users FROM ', @frantastic_app_account));
PREPARE frantastic_revoke_stmt FROM @frantastic_revoke_sql;
EXECUTE frantastic_revoke_stmt;
DEALLOCATE PREPARE frantastic_revoke_stmt;
GRANT SELECT ON university_resources.users TO $account;
GRANT INSERT (full_name, email, password_hash) ON university_resources.users TO $account;
GRANT UPDATE (full_name, password_hash) ON university_resources.users TO $account;
GRANT SELECT, INSERT, UPDATE ON university_resources.bookings TO $account;
GRANT SELECT, INSERT, UPDATE ON university_resources.loans TO $account;
GRANT SELECT ON university_resources.rooms TO $account;
GRANT SELECT ON university_resources.items TO $account;
GRANT SELECT ON university_resources.audit_events TO $account;
GRANT SELECT, INSERT, UPDATE, DELETE ON university_resources.audit_lab_notes TO $account;
GRANT SELECT ON campus_audit.* TO $account;
GRANT EXECUTE ON PROCEDURE campus_audit.import_current_log TO $account;
CREATE USER IF NOT EXISTS 'audit_lab_intruder'@'$host' IDENTIFIED BY PASSWORD '$decoy_hash' ACCOUNT LOCK;
SQL
