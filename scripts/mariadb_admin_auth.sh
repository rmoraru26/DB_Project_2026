# shellcheck shell=bash
# Sourced (not executed) by the scripts that log in to MariaDB as the
# administrator: scripts/post_start.sh, scripts/demo.sh,
# scripts/provision_local_admin_db.sh (password resolution and diagnosis) and
# scripts/doctor.sh (diagnosis only).
#
# Where the administrator password comes from.  The mariadb client reads it
# from MYSQL_PWD, never from the command line.  Two variables can supply it:
#
#   MYSQL_PWD               set by the caller (Linux `make` exports it from .env;
#                           a native server's administrator password).
#   MARIADB_ROOT_PASSWORD   the root password the mariadb service was created
#                           with (compose.yaml, from .env).  Inside the mariadb
#                           container it is always present, so scripts that run
#                           there need nothing forwarded from the host.
#
# For root: if only one of the two is set, it is used; if both are set they
# must be equal, otherwise the script stops rather than guess which one is
# right.  For any other DB_ADMIN_USER only MYSQL_PWD applies.  Without a
# password the script stops before the client is started.  Values are never
# printed; `set -u` safe.

# frantastic_require_admin_password <admin user> <script name>
# Exports a non-empty MYSQL_PWD for the client, or prints why not and returns 2.
frantastic_require_admin_password() {
    local user=${1:-root} who=${2:-mariadb_admin_auth}
    local given=${MYSQL_PWD:-} service=${MARIADB_ROOT_PASSWORD:-}
    if [ "$user" = root ] && [ -n "$service" ]; then
        if [ -n "$given" ] && [ "$given" != "$service" ]; then
            cat >&2 <<EOF
$who: MYSQL_PWD and MARIADB_ROOT_PASSWORD are both set but differ (values not shown).
Refusing to guess which root password is correct.  Both normally come from .env:
an older value exported in this shell, or a .env changed after the containers
were created, causes this.  Unset the stale variable (or re-create the
containers from the current .env) and retry.
EOF
            return 2
        fi
        given=$service
    fi
    if [ -z "$given" ]; then
        if [ "$user" = root ]; then
            cat >&2 <<EOF
$who: no MariaDB root password is available: neither MYSQL_PWD nor
MARIADB_ROOT_PASSWORD is set (or both are empty).  In the Docker setup the
mariadb service gets MARIADB_ROOT_PASSWORD from .env; check that .env defines a
non-empty MARIADB_ROOT_PASSWORD.  For a native server, export MYSQL_PWD.
EOF
        else
            echo "$who: no password for the MariaDB administrator '$user': set MYSQL_PWD." >&2
        fi
        return 2
    fi
    MYSQL_PWD=$given
    export MYSQL_PWD
}

# frantastic_login_failure_kind <client output> <exit status>
# Prints one of: no-password, rejected, denied, unreachable, docker,
# client-missing, other.
frantastic_login_failure_kind() {
    local out=$1 status=${2:-1}
    case "$out" in
        *"ERROR 1045"*"using password: NO"*) echo no-password; return ;;
        *"ERROR 1045"*) echo rejected; return ;;
        *"ERROR 1044"*|*"ERROR 1130"*|*"ERROR 1698"*|*"ERROR 4151"*) echo denied; return ;;
        *"ERROR 2002"*|*"ERROR 2003"*|*"ERROR 2005"*|*"ERROR 2006"*|*"ERROR 2013"*) echo unreachable; return ;;
        *"is not running"*|*"no such service"*|*"No such container"*|*"Cannot connect to the Docker daemon"*|*"failed to connect to the docker API"*)
            echo docker; return ;;
    esac
    if [ "$status" = 127 ] || [ "$status" = 126 ]; then echo client-missing; return; fi
    echo other
}

# frantastic_explain_admin_login_failure <client output> <exit status> <admin user>
# Explains a failed administrator login on stderr.  The client's own message is
# printed by the caller; it never contains the password.
frantastic_explain_admin_login_failure() {
    local out=$1 status=${2:-1} user=${3:-root} account
    if [ "$user" = root ]; then account="the root"; else account="the '$user'"; fi
    case "$(frantastic_login_failure_kind "$out" "$status")" in
        no-password) cat >&2 <<EOF

The MariaDB client sent NO password ("using password: NO").  This is not a
password mismatch and says nothing about the database volume: the password did
not reach the client process.  Check that .env defines a non-empty
MARIADB_ROOT_PASSWORD (values are never shown), and, if MARIADB_CLIENT runs the
client through "docker compose exec", that it forwards the password with
-e MYSQL_PWD.
  Linux/macOS:  make doctor
  Windows:      .\frantastic.cmd up   (checks .env before it starts anything)
EOF
        ;;
        rejected) cat >&2 <<EOF

The server is running but rejects $account password that was sent
("using password: YES").  The usual cause is a database volume that was
initialised with the passwords of an earlier .env: the MariaDB image applies
MARIADB_ROOT_PASSWORD (and creates campus_app) only when it initialises an EMPTY
volume, and a fresh copy, a deleted .env or a re-run of make_env.sh creates new
passwords while the volume keeps the old ones.  A .env edited after the volume
was created has the same effect.

  Keep the data:
    * put the earlier .env back if you still have it (any platform), or
    * Linux/macOS: make repair-credentials   (sets the stored passwords to the ones in .env)
  Start over -- DELETES the database and audit-log volumes, only for disposable data:
    * Linux/macOS: make reset && make up
    * Windows:     docker compose down --volumes   (in the project folder), then .\frantastic.cmd up

  Linux/macOS: make doctor shows the details.
EOF
        ;;
        denied) cat >&2 <<EOF

The server refused $account login for a reason other than a wrong password
(see the MariaDB error above: account, host or authentication plugin).
Changing .env will not fix this; check the account definition on the server.
EOF
        ;;
        unreachable) cat >&2 <<EOF

The client could not connect to the MariaDB server; this is not an
authentication problem.  Check that the mariadb container is running and
healthy:  docker compose ps   and   docker compose logs mariadb
EOF
        ;;
        docker) cat >&2 <<EOF

Docker could not run the client in the mariadb container (see the message
above).  Check that Docker is running and the stack is up:  docker compose ps
EOF
        ;;
        client-missing) cat >&2 <<EOF

The MariaDB client program was not found (exit status $status).  Check
MARIADB_CLIENT, or run the script inside the mariadb container.
EOF
        ;;
        *) cat >&2 <<EOF

Unexpected error from the MariaDB client (exit status $status); the message
above is the client's own.
EOF
        ;;
    esac
}
