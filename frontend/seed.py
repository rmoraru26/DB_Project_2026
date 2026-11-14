"""Stand-alone maintenance utility: loads the official booking catalogue.

The booking pages offer a fixed catalogue (frontend/app.py: items_home and
rooms_home).  This script inserts the matching rows into `items` and `rooms`.
database/seed.sql, the supported initialisation path (scripts/setup_database.sh,
make up), loads the demo data and is not replaced or changed by this script.

It is NOT part of the web application:

* The web app's account campus_app has no INSERT privilege on items or rooms,
  on purpose, and does not get one.  This script therefore never uses the web
  app's connection, its DB_USER/DB_PASSWORD or anything from app.py.
* It needs a privileged account, named explicitly with the same variables as
  the repository's other operator scripts (scripts/setup_database.sh):

      DB_ADMIN_USER   the MariaDB account to seed with (no default)
      MYSQL_PWD       its password (no default)

  DB_HOST, DB_PORT and DB_NAME are read as usual.  Without both variables
  the script stops before connecting; it never falls back to root, to
  campus_app or to another password.

Run once, from the frontend directory, against a database that does not have
these rows yet:

    DB_ADMIN_USER=... MYSQL_PWD=... python seed.py

Both INSERTs run in one transaction: either the whole catalogue is added or
nothing is.  The INSERTs are not idempotent (items.asset_tag is unique), so a
second run fails with ER 1062 and changes nothing.
"""
import os
import sys

import pymysql

APP_ACCOUNT = "campus_app"

ITEMS_SQL = """
    INSERT INTO items (name, category, asset_tag, status) VALUES
    ('Vacuum', 'Cleaning Items', 'Vacuum A', 'available'),
    ('Vacuum', 'Cleaning Items', 'Vacuum B', 'available'),
    ('Vacuum', 'Cleaning Items', 'Vacuum C', 'available'),
    ('Mop', 'Cleaning Items', 'Mop A', 'available'),
    ('Mop', 'Cleaning Items', 'Mop B', 'available'),
    ('Mop', 'Cleaning Items', 'Mop C', 'available'),
    ('Iron', 'Cleaning Items', 'Iron A', 'available'),
    ('Iron', 'Cleaning Items', 'Iron B', 'available'),
    ('Iron', 'Cleaning Items', 'Iron C', 'available'),
    ('Broom', 'Cleaning Items', 'Broom A', 'available'),
    ('Broom', 'Cleaning Items', 'Broom B', 'available'),
    ('Broom', 'Cleaning Items', 'Broom C', 'available'),

    ('Chess', 'Board Games', 'Chess A', 'available'),
    ('Chess', 'Board Games', 'Chess B', 'available'),
    ('Chess', 'Board Games', 'Chess C', 'available'),
    ('Monopoly', 'Board Games', 'Monopoly A', 'available'),
    ('Monopoly', 'Board Games', 'Monopoly B', 'available'),
    ('Monopoly', 'Board Games', 'Monopoly C', 'available'),
    ('Settlers of Catan', 'Board Games', 'Settlers of Catan A', 'available'),
    ('Settlers of Catan', 'Board Games', 'Settlers of Catan B', 'available'),
    ('Settlers of Catan', 'Board Games', 'Settlers of Catan C', 'available'),
    ('Scrabble', 'Board Games', 'Scrabble A', 'available'),
    ('Scrabble', 'Board Games', 'Scrabble B', 'available'),
    ('Scrabble', 'Board Games', 'Scrabble C', 'available'),
    ('Battleship', 'Board Games', 'Battleship A', 'available'),
    ('Battleship', 'Board Games', 'Battleship B', 'available'),
    ('Battleship', 'Board Games', 'Battleship C', 'available'),

    ('Basketball', 'Sports Items', 'Basketball A', 'available'),
    ('Basketball', 'Sports Items', 'Basketball B', 'available'),
    ('Basketball', 'Sports Items', 'Basketball C', 'available'),
    ('Football', 'Sports Items', 'Football A', 'available'),
    ('Football', 'Sports Items', 'Football B', 'available'),
    ('Football', 'Sports Items', 'Football C', 'available'),
    ('Frisbee', 'Sports Items', 'Frisbee A', 'available'),
    ('Frisbee', 'Sports Items', 'Frisbee B', 'available'),
    ('Frisbee', 'Sports Items', 'Frisbee C', 'available'),
    ('Tennis Racket', 'Sports Items', 'Tennis Racket A', 'available'),
    ('Tennis Racket', 'Sports Items', 'Tennis Racket B', 'available'),
    ('Tennis Racket', 'Sports Items', 'Tennis Racket C', 'available'),

    ('Speaker', 'Electronics', 'Speaker A', 'available'),
    ('Speaker', 'Electronics', 'Speaker B', 'available'),
    ('Speaker', 'Electronics', 'Speaker C', 'available'),
    ('PS5 Controller', 'Electronics', 'PS5 Controller A', 'available'),
    ('PS5 Controller', 'Electronics', 'PS5 Controller B', 'available'),
    ('PS5 Controller', 'Electronics', 'PS5 Controller C', 'available'),
    ('Headphones', 'Electronics', 'Headphones A', 'available'),
    ('Headphones', 'Electronics', 'Headphones B', 'available'),
    ('Headphones', 'Electronics', 'Headphones C', 'available'),
    ('Nintendo Switch', 'Electronics', 'Nintendo Switch A', 'available'),
    ('Nintendo Switch', 'Electronics', 'Nintendo Switch B', 'available'),
    ('Nintendo Switch', 'Electronics', 'Nintendo Switch C', 'available'),
    ('Gameboy', 'Electronics', 'Gameboy A', 'available'),
    ('Gameboy', 'Electronics', 'Gameboy B', 'available'),
    ('Gameboy', 'Electronics', 'Gameboy C', 'available');
"""

ROOMS_SQL = """
    INSERT INTO rooms (name, capacity, status) VALUES
    ('Study Room', 4, 'available'),
    ('Meeting Room', 10, 'available'),
    ('Studio Room', 4, 'available'),
    ('Practice Room', 2, 'available'),
    ('Cinema Room', 15, 'available');
"""


class SeedConfigError(Exception):
    """The maintenance credentials are missing or unusable; the message names no secret."""


def maintenance_connection():
    """A connection with the explicitly configured maintenance account.

    Raises SeedConfigError before any connection attempt when DB_ADMIN_USER or
    MYSQL_PWD is missing, or when DB_ADMIN_USER names the web application account.
    """
    user = os.environ.get("DB_ADMIN_USER") or ""
    password = os.environ.get("MYSQL_PWD") or ""
    missing = [name for name, value in (("DB_ADMIN_USER", user), ("MYSQL_PWD", password)) if not value]
    if missing:
        raise SeedConfigError(
            "Not seeding: " + " and ".join(missing) + " must be set explicitly. seed.py needs a "
            "privileged maintenance account and does not fall back to root or to the web app's "
            "account. Example: DB_ADMIN_USER=<account> MYSQL_PWD=<its password> python seed.py")
    if user == APP_ACCOUNT:
        raise SeedConfigError(
            f"Not seeding: DB_ADMIN_USER is {APP_ACCOUNT}, the web application account, which has no "
            "INSERT privilege on items or rooms by design. Name a maintenance account instead.")
    try:
        port = int(os.environ.get("DB_PORT", "3306"))
    except ValueError:
        raise SeedConfigError("Not seeding: DB_PORT is not a number.") from None
    return pymysql.connect(
        host=os.environ.get("DB_HOST", "127.0.0.1"),
        port=port,
        user=user,
        password=password,
        database=os.environ.get("DB_NAME", "university_resources"),
        charset="utf8mb4",
        autocommit=False,
        connect_timeout=5,
    )


def _error_code(error):
    return error.args[0] if error.args else "unknown"


def main():
    """Seeds items and rooms; returns the process exit code (0 ok, 1 database error, 2 configuration)."""
    try:
        db = maintenance_connection()
    except SeedConfigError as e:
        print(e, file=sys.stderr)
        return 2
    except pymysql.err.MySQLError as e:
        # Only the error code: server messages can name accounts and hosts.
        print(f"Not seeding: could not connect to MariaDB (error {_error_code(e)}). "
              "Check DB_HOST, DB_PORT, DB_NAME, DB_ADMIN_USER and MYSQL_PWD.", file=sys.stderr)
        return 1

    try:
        with db.cursor() as cursor:
            cursor.execute(ITEMS_SQL)
            cursor.execute(ROOMS_SQL)
        db.commit()
    except pymysql.err.MySQLError as e:
        try:
            db.rollback()
        except pymysql.err.MySQLError:
            pass
        code = _error_code(e)
        hint = {1062: " The catalogue seems to be loaded already.",
                1142: " The account lacks INSERT on items or rooms."}.get(code, "")
        print(f"Seeding failed (MariaDB error {code}); nothing was changed.{hint}", file=sys.stderr)
        return 1
    finally:
        db.close()
    print("Added the official item versions and rooms to the database.")
    return 0


if __name__ == "__main__":
    # .env supplies DB_HOST/DB_PORT/DB_NAME; it never overrides variables that are already set.
    from dotenv import load_dotenv
    load_dotenv()
    raise SystemExit(main())
