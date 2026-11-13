"""Small credential helper used by the host-side, operator-only bootstrap.

The web database account can verify the existing application password hash,
but cannot create or rotate administrator roles. Database writes are performed
by the MariaDB operator connection through the guarded bootstrap procedures.
Secrets are accepted through the process environment and are never logged.
"""
import argparse
import os
import secrets
import sys

import pymysql
from werkzeug.security import generate_password_hash


EMAIL = "admin@frantastic.local"


def generate_credential():
    password = secrets.token_urlsafe(32)
    return EMAIL, password, generate_password_hash(password)


def password_matches(user, password):
    if not user or user[1] != "admin" or not user[2]:
        return False
    from werkzeug.security import check_password_hash
    try:
        return check_password_hash(user[0], password)
    except (TypeError, ValueError):
        return False


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
        if not user:
            return "MISSING"
        if user[1] != "admin":
            return "NOT_ADMIN"
        return "MATCH" if password_matches(user, password) else "MISMATCH"
    finally:
        db.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Generate or verify local administrator credentials")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--hash-environment", action="store_true",
                       help="hash FRANTASTIC_ADMIN_PASSWORD and print only the hash")
    modes.add_argument("--check-environment", action="store_true",
                       help="verify FRANTASTIC_ADMIN_PASSWORD against the local admin row")
    modes.add_argument("--password-only", action="store_true",
                       help="generate a password and print it for a protected local file writer")
    args = parser.parse_args(argv)
    if args.hash_environment:
        password = os.environ.get("FRANTASTIC_ADMIN_PASSWORD")
        if not password:
            print("FRANTASTIC_ADMIN_PASSWORD is missing", file=sys.stderr)
            return 2
        print(generate_password_hash(password))
        return 0
    if args.check_environment:
        password = os.environ.get("FRANTASTIC_ADMIN_PASSWORD")
        if not password:
            print("FRANTASTIC_ADMIN_PASSWORD is missing", file=sys.stderr)
            return 2
        try:
            print(check_database_password(password))
        except (pymysql.err.MySQLError, KeyError, ValueError):
            print("Could not verify the local administrator against MariaDB", file=sys.stderr)
            return 2
        return 0

    if args.password_only:
        print(secrets.token_urlsafe(32))
        return 0

    email, password, password_hash = generate_credential()
    sys.stdout.write(f"{email}\n{password}\n{password_hash}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
