"""Credential helper for the per-installation demo student.

Used by the host-side, operator-only bootstrap (scripts/bootstrap_demo.sh on
Linux, which needs GNU coreutils `stat -c` and `mv -T` and is untested on
macOS; frantastic.ps1 on Windows); it is not part of the web application
and app.py never imports it.

The demo student is an ordinary account with the role `student`.  Its password
is generated here with the `secrets` module, hashed with the same Werkzeug
function the application uses for every registration, and verified with the
same function the login route uses.  This helper writes nothing as campus_app:
it only reads the stored hash to verify a password.  The row is written by the
MariaDB operator connection through the procedures of migration 007.  Under its
column grants campus_app could still create a student at the demo address
(/register, if no such row exists yet) and change the row's password_hash (the
password-change page); it cannot write role or is_active, so the account stays
a student.

Secrets are accepted through the process environment only (never argv) and
are never logged.  `--password-only` prints a new password on stdout for the
caller's protected file writer; nothing else ever prints one.
"""
import argparse
import os
import secrets
import sys

import pymysql
from werkzeug.security import check_password_hash, generate_password_hash


EMAIL = "demo.student@frantastic.local"
PASSWORD_ENV = "FRANTASTIC_DEMO_PASSWORD"
# 18 random bytes: 144 bits, 24 URL-safe characters (A-Z a-z 0-9 _ -).
PASSWORD_BYTES = 18


def new_password():
    return secrets.token_urlsafe(PASSWORD_BYTES)


def generate_credential():
    password = new_password()
    return EMAIL, password, generate_password_hash(password)


def account_state(user, password):
    """What the login route would decide for this row and password.

    `user` is (password_hash, role, is_active) or None.  Returns one of
    MISSING, NOT_STUDENT, INACTIVE, MATCH, MISMATCH.  Only MATCH means the
    credential logs in as a student.
    """
    if not user:
        return "MISSING"
    if user[1] != "student":
        return "NOT_STUDENT"
    try:
        matches = bool(user[0]) and check_password_hash(user[0], password)
    except (TypeError, ValueError, AttributeError):
        matches = False
    if not matches:
        return "MISMATCH"
    if not user[2]:
        return "INACTIVE"
    return "MATCH"


def check_database_password(password):
    db = pymysql.connect(
        host=os.getenv("DB_HOST", "mariadb"),
        port=int(os.getenv("DB_PORT", "3306")),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.getenv("DB_NAME", "university_resources"),
        charset="utf8mb4",
        connect_timeout=5,
    )
    try:
        with db.cursor() as cursor:
            cursor.execute("SELECT password_hash, role, is_active FROM users WHERE email=%s", (EMAIL,))
            user = cursor.fetchone()
        return account_state(user, password)
    finally:
        db.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Generate or verify the local demo-student credential")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--hash-environment", action="store_true",
                       help=f"hash {PASSWORD_ENV} and print only the hash")
    modes.add_argument("--check-environment", action="store_true",
                       help=f"verify {PASSWORD_ENV} against the demo student's row in MariaDB")
    modes.add_argument("--password-only", action="store_true",
                       help="generate a password and print it for a protected local file writer")
    args = parser.parse_args(argv)

    if args.password_only:
        print(new_password())
        return 0

    password = os.environ.get(PASSWORD_ENV)
    if not password:
        print(f"{PASSWORD_ENV} is missing", file=sys.stderr)
        return 2
    if args.hash_environment:
        print(generate_password_hash(password))
        return 0
    try:
        print(check_database_password(password))
    except (pymysql.err.MySQLError, KeyError, ValueError):
        print("Could not verify the demo student against MariaDB", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
