"""Tests for the stand-alone maintenance utility frontend/seed.py.

No database: pymysql.connect is replaced by a recording stub.  The tests
check the utility's contract (explicit maintenance credentials, no fallback,
no secrets in its output, nothing shared with the web app); whether a given
MariaDB account may really INSERT into items and rooms is a property of the
server's grants and is not tested here.
"""
import ast
import pathlib

import pymysql
import pytest

import seed

FRONTEND = pathlib.Path(seed.__file__).parent
SECRET = "maintenance-s3cret-value"


class StubCursor:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, args=None):
        self.conn.log.append(("execute", " ".join(sql.split())[:24]))
        if self.conn.fail_on and self.conn.fail_on in sql:
            raise self.conn.error


class StubConnection:
    def __init__(self, fail_on=None, error=None):
        self.log, self.fail_on, self.error = [], fail_on, error

    def cursor(self):
        return StubCursor(self)

    def commit(self):
        self.log.append(("commit",))

    def rollback(self):
        self.log.append(("rollback",))

    def close(self):
        self.log.append(("close",))


@pytest.fixture()
def connects(monkeypatch):
    """Replaces pymysql.connect; returns the list of its calls.  `connects.result` is what it returns or raises."""
    class Calls(list):
        result = None

    calls = Calls()
    calls.result = StubConnection()

    def connect(**kwargs):
        calls.append(kwargs)
        if isinstance(calls.result, Exception):
            raise calls.result
        return calls.result

    monkeypatch.setattr(pymysql, "connect", connect)
    for name in ("DB_ADMIN_USER", "MYSQL_PWD", "DB_USER", "DB_PASSWORD", "MARIADB_ROOT_PASSWORD",
                 "DB_HOST", "DB_PORT", "DB_NAME"):
        monkeypatch.delenv(name, raising=False)
    return calls


@pytest.mark.parametrize("environment", [
    {},
    {"DB_ADMIN_USER": "seed_operator"},                                   # no password
    {"MYSQL_PWD": SECRET},                                                # no account: root is not assumed
    {"DB_ADMIN_USER": "", "MYSQL_PWD": SECRET},
    {"DB_ADMIN_USER": "seed_operator", "MYSQL_PWD": ""},
    {"DB_USER": "root", "DB_PASSWORD": SECRET},                           # the web app's variables are not used
    {"DB_USER": "campus_app", "DB_PASSWORD": SECRET},
    {"MARIADB_ROOT_PASSWORD": SECRET},                                    # nor the Docker root password
])
def test_missing_maintenance_credentials_stop_before_connecting(connects, monkeypatch, capsys, environment):
    for name, value in environment.items():
        monkeypatch.setenv(name, value)
    assert seed.main() == 2
    assert connects == []
    out = capsys.readouterr()
    assert "DB_ADMIN_USER" in out.err or "MYSQL_PWD" in out.err          # says what to set
    assert SECRET not in out.err + out.out


def test_web_application_account_is_refused(connects, monkeypatch, capsys):
    monkeypatch.setenv("DB_ADMIN_USER", "campus_app")
    monkeypatch.setenv("MYSQL_PWD", SECRET)
    assert seed.main() == 2
    assert connects == []
    out = capsys.readouterr()
    assert "campus_app" in out.err and SECRET not in out.err + out.out


def test_seeds_with_the_explicit_account_in_one_transaction(connects, monkeypatch, capsys):
    monkeypatch.setenv("DB_ADMIN_USER", "seed_operator")
    monkeypatch.setenv("MYSQL_PWD", SECRET)
    monkeypatch.setenv("DB_HOST", "db.example.internal")
    monkeypatch.setenv("DB_PORT", "3307")
    assert seed.main() == 0
    (call,) = connects
    assert (call["user"], call["password"]) == ("seed_operator", SECRET)
    assert (call["host"], call["port"], call["database"]) == ("db.example.internal", 3307, "university_resources")
    assert call["autocommit"] is False
    assert connects.result.log == [("execute", "INSERT INTO items (name,"), ("execute", "INSERT INTO rooms (name,"),
                                   ("commit",), ("close",)]
    out = capsys.readouterr()
    assert SECRET not in out.err + out.out


@pytest.mark.parametrize("fail_on,code", [("INSERT INTO items", 1062), ("INSERT INTO rooms", 1142)])
def test_failed_seed_is_rolled_back_without_leaking_details(connects, monkeypatch, capsys, fail_on, code):
    monkeypatch.setenv("DB_ADMIN_USER", "seed_operator")
    monkeypatch.setenv("MYSQL_PWD", SECRET)
    connects.result = StubConnection(fail_on, pymysql.err.OperationalError(
        code, f"server text naming 'seed_operator'@'10.0.0.5' and {SECRET}"))
    assert seed.main() == 1
    log = connects.result.log
    assert ("commit",) not in log and log[-2:] == [("rollback",), ("close",)]
    out = capsys.readouterr()
    assert str(code) in out.err and "nothing was changed" in out.err
    assert SECRET not in out.err + out.out and "10.0.0.5" not in out.err + out.out


def test_connection_failure_reports_only_the_error_code(connects, monkeypatch, capsys):
    monkeypatch.setenv("DB_ADMIN_USER", "seed_operator")
    monkeypatch.setenv("MYSQL_PWD", SECRET)
    connects.result = pymysql.err.OperationalError(
        1045, f"Access denied for user 'seed_operator'@'10.0.0.5' (password {SECRET})")
    assert seed.main() == 1
    assert len(connects) == 1                                             # one attempt, no second account
    out = capsys.readouterr()
    assert "1045" in out.err
    assert SECRET not in out.err + out.out and "10.0.0.5" not in out.err + out.out


def test_seed_is_independent_of_the_web_application():
    source = (FRONTEND / "seed.py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.add((node.module or "").split(".")[0])
    assert imported == {"os", "sys", "pymysql", "dotenv"}                  # not app, not flask
    code = source.replace(ast.get_docstring(tree, clean=False), "")       # the docstring explains what is not used
    assert "get_db" not in code and "DB_PASSWORD" not in code and '"DB_USER"' not in code
    assert "MARIADB_ROOT_PASSWORD" not in code and '"root"' not in code
    app_source = (FRONTEND / "app.py").read_text(encoding="utf-8")
    assert "import seed" not in app_source and "from seed" not in app_source


def test_seed_still_holds_the_official_catalogue():
    assert seed.ITEMS_SQL.count("'available')") == 54 and seed.ROOMS_SQL.count("'available')") == 5
    for name in ("Vacuum A", "Settlers of Catan C", "Gameboy C"):
        assert f"'{name}'" in seed.ITEMS_SQL
    for name in ("Study Room", "Cinema Room"):
        assert f"'{name}'" in seed.ROOMS_SQL
