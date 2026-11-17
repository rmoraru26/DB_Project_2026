"""Tests for frontend/bootstrap_demo.py, the demo-student credential helper.

No database: pymysql.connect is replaced by a stub that returns one row.  The
host-side state machine is tested in tests/shell/test_demo_bootstrap.sh and
tests/windows/test_demo_credentials.ps1, the procedures and the constraint in
tests/database/test_demo_student.sh, and the real login in test_app.py
(RUN_DB_TESTS=1 with TEST_DEMO_EMAIL / TEST_DEMO_PASSWORD).
"""
import ast
import pathlib
import re

import pymysql
import pytest
from werkzeug.security import check_password_hash, generate_password_hash

import bootstrap_demo

FRONTEND = pathlib.Path(bootstrap_demo.__file__).parent
PASSWORD = "Demo-Test_Password-0123456789"
PASSWORD_SHAPE = re.compile(r"^[A-Za-z0-9_-]{20,}$")     # what the host scripts accept in the file


def test_generated_credential_is_random_and_its_hash_verifies():
    first = bootstrap_demo.generate_credential()
    second = bootstrap_demo.generate_credential()
    assert first[0] == second[0] == "demo.student@frantastic.local"
    assert first[1] != second[1] and first[2] != second[2]
    assert check_password_hash(first[2], first[1])
    assert not check_password_hash(first[2], second[1])
    assert first[2].startswith(("scrypt:", "pbkdf2:")) and first[1] not in first[2]


def test_generated_passwords_have_the_shape_the_host_scripts_require():
    passwords = {bootstrap_demo.new_password() for _ in range(200)}
    assert len(passwords) == 200                                   # no repeats
    assert all(PASSWORD_SHAPE.match(p) for p in passwords)
    assert all(len(p) == 24 for p in passwords)                    # 18 random bytes, 144 bits


def test_password_comes_from_the_secrets_module_not_from_random():
    source = (FRONTEND / "bootstrap_demo.py").read_text(encoding="utf-8")
    imported = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.add((node.module or "").split(".")[0])
    assert "secrets" in imported and "random" not in imported
    assert imported == {"argparse", "os", "secrets", "sys", "pymysql", "werkzeug"}     # not app, not flask
    app_source = (FRONTEND / "app.py").read_text(encoding="utf-8")
    assert "bootstrap_demo" not in app_source                       # operator tool, not part of the web app


@pytest.mark.parametrize("row,password,expected", [
    (None, PASSWORD, "MISSING"),
    (("HASH", "student", 1), PASSWORD, "MATCH"),
    (("HASH", "student", 1), PASSWORD + "x", "MISMATCH"),
    (("HASH", "student", 0), PASSWORD, "INACTIVE"),
    (("HASH", "student", 0), "wrong-password", "MISMATCH"),         # a wrong password never learns the active flag
    (("HASH", "admin", 1), PASSWORD, "NOT_STUDENT"),                # never "MATCH" for a privileged row
    (("TEST_HASH_NOT_FOR_LOGIN", "student", 1), PASSWORD, "MISMATCH"),
    (("", "student", 1), PASSWORD, "MISMATCH"),
    ((None, "student", 1), PASSWORD, "MISMATCH"),
])
def test_account_state_decides_like_the_login_route(row, password, expected):
    if row and row[0] == "HASH":
        row = (generate_password_hash(PASSWORD),) + row[1:]
    assert bootstrap_demo.account_state(row, password) == expected


class StubConnection:
    def __init__(self, row):
        self.row, self.statements, self.closed = row, [], False

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, args=None):
        self.statements.append((" ".join(sql.split()), args))

    def fetchone(self):
        return self.row

    def close(self):
        self.closed = True


@pytest.fixture()
def database(monkeypatch):
    """Replaces pymysql.connect; `database.row` is the users row the stub returns."""
    class Calls(list):
        row = None
        error = None
        connection = None

    calls = Calls()

    def connect(**kwargs):
        calls.append(kwargs)
        if calls.error:
            raise calls.error
        calls.connection = StubConnection(calls.row)
        return calls.connection

    monkeypatch.setattr(pymysql, "connect", connect)
    monkeypatch.setenv("DB_USER", "campus_app")
    monkeypatch.setenv("DB_PASSWORD", "app-account-password")
    monkeypatch.setenv("DB_HOST", "db.example.internal")
    monkeypatch.setenv("DB_PORT", "3307")
    monkeypatch.delenv("DB_NAME", raising=False)
    monkeypatch.delenv(bootstrap_demo.PASSWORD_ENV, raising=False)
    return calls


def test_check_reads_only_the_demo_row_with_the_application_account(database, monkeypatch, capsys):
    database.row = (generate_password_hash(PASSWORD), "student", 1)
    monkeypatch.setenv(bootstrap_demo.PASSWORD_ENV, PASSWORD)
    assert bootstrap_demo.main(["--check-environment"]) == 0
    out = capsys.readouterr()
    assert out.out.strip() == "MATCH" and PASSWORD not in out.out + out.err
    (call,) = database
    assert (call["user"], call["host"], call["port"], call["database"]) == \
        ("campus_app", "db.example.internal", 3307, "university_resources")
    ((statement, args),) = database.connection.statements
    assert statement == "SELECT password_hash, role, is_active FROM users WHERE email=%s"
    assert args == ("demo.student@frantastic.local",)
    assert database.connection.closed


@pytest.mark.parametrize("row,expected", [
    (None, "MISSING"),
    ((generate_password_hash("another-password-entirely"), "student", 1), "MISMATCH"),
    ((generate_password_hash(PASSWORD), "admin", 1), "NOT_STUDENT"),
    ((generate_password_hash(PASSWORD), "student", 0), "INACTIVE"),
])
def test_check_reports_every_other_state_without_printing_secrets(database, monkeypatch, capsys, row, expected):
    database.row = row
    monkeypatch.setenv(bootstrap_demo.PASSWORD_ENV, PASSWORD)
    assert bootstrap_demo.main(["--check-environment"]) == 0
    out = capsys.readouterr()
    assert out.out.strip() == expected
    assert PASSWORD not in out.out + out.err and "scrypt:" not in out.out and "pbkdf2:" not in out.out


def test_check_failure_reports_no_server_detail(database, monkeypatch, capsys):
    database.error = pymysql.err.OperationalError(
        1045, "Access denied for user 'campus_app'@'10.0.0.5' (using password: YES)")
    monkeypatch.setenv(bootstrap_demo.PASSWORD_ENV, PASSWORD)
    assert bootstrap_demo.main(["--check-environment"]) == 2
    out = capsys.readouterr()
    assert out.out == "" and "10.0.0.5" not in out.err and PASSWORD not in out.err
    assert "app-account-password" not in out.err


@pytest.mark.parametrize("mode", ["--check-environment", "--hash-environment"])
def test_modes_that_need_a_password_stop_without_one(database, capsys, mode):
    assert bootstrap_demo.main([mode]) == 2
    out = capsys.readouterr()
    assert out.out == "" and bootstrap_demo.PASSWORD_ENV in out.err
    assert database == []                                           # no connection attempt


def test_hash_mode_prints_only_a_hash_of_the_environment_password(database, monkeypatch, capsys):
    monkeypatch.setenv(bootstrap_demo.PASSWORD_ENV, PASSWORD)
    assert bootstrap_demo.main(["--hash-environment"]) == 0
    out = capsys.readouterr()
    (line,) = out.out.splitlines()
    assert re.match(r"^(scrypt|pbkdf2):[A-Za-z0-9:._$-]+$", line)   # the pattern the host scripts validate
    assert check_password_hash(line, PASSWORD) and PASSWORD not in out.out + out.err
    assert database == []


def test_password_only_prints_one_new_password_and_nothing_else(database, capsys):
    assert bootstrap_demo.main(["--password-only"]) == 0
    first = capsys.readouterr()
    assert bootstrap_demo.main(["--password-only"]) == 0
    second = capsys.readouterr()
    (a,), (b,) = first.out.splitlines(), second.out.splitlines()
    assert a != b and PASSWORD_SHAPE.match(a) and PASSWORD_SHAPE.match(b)
    assert first.err == "" and database == []


def test_a_mode_is_required_and_the_password_is_never_an_argument(capsys):
    with pytest.raises(SystemExit) as stop:
        bootstrap_demo.main([])
    assert stop.value.code == 2
    with pytest.raises(SystemExit):
        bootstrap_demo.main(["--password", PASSWORD])               # no such option: secrets are not accepted in argv
    assert PASSWORD not in capsys.readouterr().out
