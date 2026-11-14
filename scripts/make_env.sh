#!/usr/bin/env bash
# Creates .env from .env.example with freshly generated random secrets.
#
#   bash scripts/make_env.sh          # does nothing if .env already exists
#
# The three secrets (MARIADB_ROOT_PASSWORD, CAMPUS_APP_PASSWORD, SECRET_KEY) are
# random per checkout, so no password is ever shared through the repository.
# .env is git-ignored and created with mode 600.  Set your own values by
# editing the file afterwards.
#
# New passwords only reach MariaDB when it initialises an EMPTY volume.  If a
# database volume of this Compose project already exists, it still holds the
# passwords of an earlier .env; the script warns about that case.

set -eu

cd "$(dirname "$0")/.."

if [ -e .env ]; then
    echo ".env already exists; leaving it unchanged."
    exit 0
fi
[ -f .env.example ] || { echo "make_env.sh: .env.example not found" >&2; exit 1; }

random_hex() {   # random_hex <bytes>
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import secrets,sys; print(secrets.token_hex(int(sys.argv[1])))" "$1"
    else
        echo "make_env.sh: need openssl or python3 to generate secrets" >&2
        exit 1
    fi
}

root_pw="r$(random_hex 16)"     # 33 chars, [0-9a-f] plus the leading letter
app_pw="a$(random_hex 16)"      # app_account.sh accepts A-Z a-z 0-9 . _ - (12+ chars)
secret_key="$(random_hex 24)"

umask 077
# tr: a Windows checkout may give .env.example CRLF line endings; .env must not
# carry them (bash would keep a trailing \r in every sourced value).
tr -d '\r' < .env.example | sed \
    -e "s|^MARIADB_ROOT_PASSWORD=.*|MARIADB_ROOT_PASSWORD=${root_pw}|" \
    -e "s|^CAMPUS_APP_PASSWORD=.*|CAMPUS_APP_PASSWORD=${app_pw}|" \
    -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${app_pw}|" \
    -e "s|^SECRET_KEY=.*|SECRET_KEY=${secret_key}|" \
    > .env

echo "Created .env with random secrets (mode 600). Never commit it."

volume="${COMPOSE_PROJECT_NAME:-campus-audit}_mariadb-data"
if command -v docker >/dev/null 2>&1 && docker volume inspect "$volume" >/dev/null 2>&1; then
    cat >&2 <<EOF

WARNING: the database volume '$volume' already exists.  It was initialised
with the passwords of an EARLIER .env, and MariaDB keeps those: the new
passwords in this .env will be rejected (ERROR 1045) until you either
  * put the earlier .env back, or
  * run 'make repair-credentials' (sets the stored passwords to this .env, keeps all data), or
  * run 'make reset' (DELETES the database and audit logs) and then 'make up'.
EOF
fi
