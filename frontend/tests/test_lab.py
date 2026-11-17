"""Tests for the Audit Lab (/lab), the health check and the database error pages.

Three groups:

* no database at all (the tour page, access control, validation, error pages);
* the in-memory fake database of tests/fakedb.py: the real routes and
  lab.perform() run every lab action, and the tests check the application's
  side (statements, ownership, rollback, error codes, @app_user_id).  The
  fake has no plugin and no triggers, so these tests say nothing about what
  MariaDB records;
* RUN_DB_TESTS=1: the lab's actions against a real MariaDB server with the
  campus_audit plugin installed, checking the records the plugin and the
  triggers really wrote.  It connects as the application account, exactly
  like the app.
"""
import json
import os
import pathlib
import random
import re
import secrets
from datetime import datetime, timedelta

import pymysql
import pytest
from flask import url_for

os.environ.setdefault("SECRET_KEY", "test-only-secret-key")

import app as webapp  # noqa: E402
import lab  # noqa: E402


@pytest.fixture()
def flask_app():
    return webapp.create_app({"TESTING": True, "SECRET_KEY": "test-only-secret-key", "DB_USER": "campus_app"})


@pytest.fixture()
def client(flask_app):
    return flask_app.test_client()


def login_as(client, user_id, role="student"):
    with client.session_transaction() as s:
        s["user_id"] = user_id
        s["role"] = role
        s["full_name"] = "Test"


def token(client):
    with client.session_transaction() as s:
        return s.setdefault("_csrf", secrets.token_urlsafe(24))


def act(client, action, **fields):
    body = {"action": action, "label": fields.pop("label", "Lab test"), "quantity": fields.pop("quantity", 3)}
    return client.post("/lab/api/action", json=body, headers={"X-CSRF-Token": token(client)})


# ---------------------------------------------------------------- tour page (no database)

def test_lab_page_is_public_and_has_the_tour(client):
    page = client.get("/lab")
    assert page.status_code == 200
    html = page.data.decode()
    for step in range(1, 10):
        assert f'data-step="{step}"' in html and f'data-goto="{step}"' in html
    for control in ("start", "skip", "next", "back", "restart"):
        assert f'data-tour="{control}"' in html
    assert 'role="progressbar"' in html and 'aria-valuemax="9"' in html
    assert 'data-logged-in="false"' in html
    assert "log in" in html.lower()


def test_lab_page_offers_every_action_and_nothing_else(client):
    html = client.get("/lab").data.decode()
    offered = set(__import__("re").findall(r'data-action="([a-z_]+)"', html))
    assert offered == set(lab.ACTIONS)


def test_homepage_points_newcomers_to_the_tour(client):
    html = client.get("/").data.decode()
    assert 'href="/lab"' in html and "Start Guided Tour" in html          # the official homepage's label


def test_homepage_audit_events_button_opens_the_event_explorer(flask_app, client):
    """Regression test: the official button used to link to "#"."""
    html = client.get("/").data.decode()
    (anchor,) = re.findall(r"<a\b[^>]*>\s*Explore Audit Events\s*</a>", html)
    href = re.search(r'href="([^"]*)"', anchor).group(1)
    assert href != "#" and href == "/lab?step=7"
    with flask_app.test_request_context():
        assert href == url_for("lab", step=7)
    assert "btn btn-lg custom-grey-btn px-4" in anchor                      # the official styling
    # The target exists, step 7 is the explorer, and the page's script opens the requested step.
    page = client.get(href)
    assert page.status_code == 200
    step = re.search(r'<section class="lab-step" data-step="7".*?</h2>', page.data.decode(), re.S).group(0)
    assert "Explore events" in step
    script = (pathlib.Path(webapp.__file__).parent / "static" / "lab.js").read_text(encoding="utf-8")
    assert 'params.get("step")' in script
    # The link is navigation only: the explorer's data still needs a login,
    # and students stay scoped to their own records (tests further down).
    assert client.get("/lab/api/events").status_code == 401
    assert client.get("/lab/api/history").status_code == 401


def test_lab_page_keeps_the_site_layout(client):
    html = client.get("/lab").data.decode()
    assert 'href="/static/styles.css"' in html and 'href="/static/lab.css"' in html
    assert '<script src="/static/lab.js"></script>' in html
    assert "Smart Campus" in html and 'class="navbar' in html              # the official navigation bar
    assert 'class="lab-title' in html and "custom-filled-btn" in html


DEMO_SECRETS = ("campus-demo", "TEST_HASH_NOT_FOR_LOGIN")


def test_no_demo_credentials_in_pages_or_static_assets(client):
    import pathlib
    frontend = pathlib.Path(webapp.__file__).parent
    served = [client.get(p).data.decode() for p in ("/lab", "/", "/login", "/register")]
    files = [f.read_text(encoding="utf-8") for f in (frontend / "static").glob("*.*")
             if f.suffix in (".js", ".css")]
    files += [f.read_text(encoding="utf-8") for f in (frontend / "templates").rglob("*.html")]
    for text in served + files:
        for secret in DEMO_SECRETS:
            assert secret not in text
    lab_page = served[0]
    assert "@example.edu" not in lab_page and "password" not in lab_page.lower()


def test_lab_page_carries_the_csrf_token_for_scripts(client):
    html = client.get("/lab").data.decode()
    with client.session_transaction() as s:
        assert f'<meta name="csrf-token" content="{s["_csrf"]}">' in html


# ---------------------------------------------------------------- API access control (no database)

@pytest.mark.parametrize("path", ["/lab/api/plugin", "/lab/api/events", "/lab/api/history", "/lab/api/notes"])
def test_read_endpoints_need_login(client, path):
    response = client.get(path)
    assert response.status_code == 401
    assert response.get_json()["error"] == "login_required"


@pytest.mark.parametrize("path", ["/lab/api/action", "/lab/api/import", "/lab/api/reset"])
def test_write_endpoints_need_csrf_even_when_logged_in(client, path):
    login_as(client, 1)
    response = client.post(path, json={"action": "create"})
    assert response.status_code == 400
    assert response.get_json()["error"] == "csrf"


@pytest.mark.parametrize("path", ["/lab/api/action", "/lab/api/import", "/lab/api/reset"])
def test_write_endpoints_need_login(client, path):
    response = client.post(path, json={"action": "create"}, headers={"X-CSRF-Token": token(client)})
    assert response.status_code == 401


@pytest.mark.parametrize("body,message", [
    ({"action": "drop_everything"}, "Unknown lab action"),
    ({"action": "DROP TABLE users"}, "Unknown lab action"),
    ({"action": None}, "Unknown lab action"),
    ({"action": "create", "label": "x" * 61, "quantity": 1}, "1 to 60 characters"),
    ({"action": "create", "label": "bad\x00label", "quantity": 1}, "control characters"),
    ({"action": "create", "label": "   ", "quantity": 1}, "1 to 60 characters"),
    ({"action": "create", "label": "ok", "quantity": 0}, "between 1 and 100"),
    ({"action": "update", "quantity": 101}, "between 1 and 100"),
    ({"action": "rollback", "quantity": "2; DROP TABLE x"}, "whole number"),
])
def test_actions_are_validated_before_any_database_access(client, body, message):
    login_as(client, 1)
    # No database is configured for these tests: reaching get_db() would fail with 503.
    response = client.post("/lab/api/action", json=body, headers={"X-CSRF-Token": token(client)})
    assert response.status_code == 400
    assert message in response.get_json()["message"]


def test_lab_actions_are_throttled_per_user(flask_app, client):
    login_as(client, 7)
    for _ in range(flask_app.lab_throttle.max_failures):
        flask_app.lab_throttle.record_failure(7)
    response = client.post("/lab/api/action", json={"action": "create"}, headers={"X-CSRF-Token": token(client)})
    assert response.status_code == 429


@pytest.mark.parametrize("args,message", [
    ({"type": "statement' OR 1=1 --"}, "Unknown event type"),
    ({"table": "rooms; DROP"}, "Table names"),
    ({"account": "x' OR '1"}, "Unsupported characters"),
    ({"outcome": "maybe"}, "Unknown outcome"),
    ({"since": "forever"}, "Unknown time range"),
])
def test_explorer_filters_are_allow_listed(args, message):
    with pytest.raises(lab.LabError) as refused:
        lab.explore_events(None, args, journal=[[1, "2026-11-03 10:00:00.000000"]])
    assert message in str(refused.value)


@pytest.mark.parametrize("args", [{"table": "mysql.user"}, {"action": "TRUNCATE"}, {"since": "1; SELECT"}])
def test_history_filters_are_allow_listed(args):
    with pytest.raises(lab.LabError):
        lab.explore_history(None, args, user_id=1)


# ---------------------------------------------------------------- database failures (no database)

@pytest.fixture()
def unreachable_app():
    """The app pointed at a port where no server listens, like a stopped database container."""
    return webapp.create_app({"TESTING": True, "SECRET_KEY": "test-only-secret-key", "DB_USER": "campus_app",
                              "DB_HOST": "127.0.0.1", "DB_PORT": 1, "DB_PASSWORD": "x"})


def test_login_without_database_is_a_503_page_not_a_500(unreachable_app):
    """Regression test: a failed connection used to surface as 'Internal Server Error'."""
    c = unreachable_app.test_client()
    response = c.post("/login", data={"email": "a@b.cd", "password": "x", "csrf_token": token(c)})
    assert response.status_code == 503
    assert b"cannot reach its database" in response.data
    assert b"Internal Server Error" not in response.data


def test_register_without_database_is_a_503_page(unreachable_app):
    c = unreachable_app.test_client()
    response = c.post("/register", data={"full_name": "A", "email": "a@b.cd", "password": "longenough",
                                         "confirm_password": "longenough", "csrf_token": token(c)})
    assert response.status_code == 503 and b"make doctor" in response.data


def test_healthz_reports_the_database_failure(unreachable_app):
    response = unreachable_app.test_client().get("/healthz")
    assert response.status_code == 503
    assert response.get_json()["status"] == "error"


def test_lab_api_reports_the_database_failure_as_json(unreachable_app):
    c = unreachable_app.test_client()
    login_as(c, 1)
    response = c.get("/lab/api/plugin")
    assert response.status_code == 503
    assert response.get_json()["error"] == "database_unavailable"


def test_database_error_page_never_shows_the_password(unreachable_app):
    c = unreachable_app.test_client()
    unreachable_app.config["DB_PASSWORD"] = "s3cret-should-not-leak"
    response = c.post("/login", data={"email": "a@b.cd", "password": "x", "csrf_token": token(c)})
    assert b"s3cret-should-not-leak" not in response.data


# ---------------------------------------------------------------- permissions and plugin state (fake database)

def test_lab_api_accepts_a_valid_token_and_runs_on_the_request_connection(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid)
    response = fake_client.post("/lab/api/reset", headers={"X-CSRF-Token": token(fake_client)})
    assert response.status_code == 200 and response.get_json() == {"removed": 0, "notes": []}
    (conn,) = fake.connections
    assert conn.statements[0] == ("SET @app_user_id = %s", (uid,))
    assert fake.writes == [(conn.id, uid, "DELETE FROM audit_lab_notes WHERE owner_user_id = %s")]


def test_lab_api_refuses_deactivated_accounts(fake, fake_client):
    uid = fake.add_user("gone@example.edu", active=False)
    login_as(fake_client, uid)
    assert fake_client.get("/lab/api/notes").status_code == 401
    response = fake_client.post("/lab/api/reset", headers={"X-CSRF-Token": token(fake_client)})
    assert response.status_code in (400, 401)        # session ended: the token went with it
    assert fake.writes == []


def test_scope_all_needs_the_admin_role_in_the_database(fake, fake_client):
    uid = fake.add_user("ada@example.edu", role="student")
    login_as(fake_client, uid, "admin")              # forged or stale session role
    with fake_client.session_transaction() as s:
        s["lab_journal"] = []
    events = fake_client.get("/lab/api/events?scope=all&since=all").get_json()
    assert events == {"events": [], "scope": "mine"}


def test_plugin_unavailable_is_reported_safely(fake, fake_client):
    fake.plugin_installed = False
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid)
    state = fake_client.get("/lab/api/plugin")
    assert state.status_code == 200
    data = state.get_json()
    assert data["active"] is False and data["plugin"] is None and data["import_available"] is False
    imported = fake_client.post("/lab/api/import", headers={"X-CSRF-Token": token(fake_client)})
    assert imported.status_code == 503
    body = imported.get_json()
    assert body["error"] == "lab" and "migration 003" in body["message"]
    assert "fake-app-password" not in imported.get_data(as_text=True)


def test_lab_page_shows_the_admin_scope_only_to_admins(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid, "student")
    html = fake_client.get("/lab").data.decode()
    assert 'data-logged-in="true"' in html and 'name="scope"' not in html


# ---------------------------------------------------------------- lab actions (fake database)
#
# The real routes and lab.perform() against tests/fakedb.py.  Checked here:
# the outcome the endpoint reports, the state of audit_lab_notes, rollback,
# error codes, and the @app_user_id every write statement ran with.
#
# Not checked here, because the fake has neither the plugin nor the triggers:
# result["plugin"]["events"] and result["history"] are always empty.  What
# MariaDB really records is covered only by the RUN_DB_TESTS=1 group below.

NO_IMPORT = {"total_lines": 0, "invalid_lines_skipped": 0, "newly_imported": 0}
OK = {"ok": True, "error_code": None}


def lab_student(fake, client, email="ada@example.edu"):
    uid = fake.add_user(email)
    login_as(client, uid)
    return uid


def note_state(fake):
    return sorted((n["note_id"], n["owner_user_id"], n["label"], n["quantity"]) for n in fake.lab_notes)


def events_from(conn, statement):
    """The connection's events (execute/commit/rollback/close), starting at `statement`."""
    return conn.events[conn.events.index(("execute", statement)):]


def test_fake_create_inserts_a_row_owned_by_the_request_user(fake, fake_client):
    uid = lab_student(fake, fake_client)
    response = act(fake_client, "create", label="First", quantity=4)
    assert response.status_code == 200
    result = response.get_json()
    (conn,) = fake.connections
    (note,) = fake.lab_notes                                   # still there after the connection closed: committed
    assert (note["owner_user_id"], note["label"], note["quantity"]) == (uid, "First", 4)
    assert result["action"] == "create" and result["statement"] == lab.SQL["create"]
    assert result["outcome"] == dict(OK, message=f"Inserted lab row #{note['note_id']}.")
    assert result["connection_id"] == conn.id and conn.kwargs["user"] == "campus_app"
    assert [(n["note_id"], n["label"], n["quantity"]) for n in result["notes"]] == [(note["note_id"], "First", 4)]
    assert events_from(conn, lab.SQL["create"])[1] == ("commit",)
    assert fake.writes == [(conn.id, uid, lab.SQL["create"])]
    # Fake database: an empty import and no records, by construction.
    assert result["plugin"] == {"imported": True, "import": NO_IMPORT, "error": None, "events": []}
    assert result["history"] == []
    with fake_client.session_transaction() as s:
        assert s["lab_journal"] == [[conn.id, result["started_at"]]]


def test_fake_update_changes_only_the_request_users_latest_row(fake, fake_client):
    alice = lab_student(fake, fake_client)
    bob = fake.add_user("bob@example.edu")
    older = fake.add_note(alice, "older", 2)
    latest = fake.add_note(alice, "latest", 5)
    bobs = fake.add_note(bob, "bob", 9)                        # the newest row of the table, but not Alice's
    response = act(fake_client, "update", quantity=7)
    assert response.status_code == 200
    result = response.get_json()
    assert result["outcome"] == dict(OK, message=f"Row #{latest}: quantity 5 -> 7.")
    assert note_state(fake) == [(older, alice, "older", 2), (latest, alice, "latest", 7), (bobs, bob, "bob", 9)]
    (conn,) = fake.connections
    assert (lab.SQL["update"], (7, latest, alice)) in conn.statements
    assert events_from(conn, lab.SQL["update"])[1] == ("commit",)
    assert fake.writes == [(conn.id, alice, lab.SQL["update"])]
    assert [n["note_id"] for n in result["notes"]] == [latest, older]        # Alice's rows only, newest first


def test_fake_delete_removes_only_the_request_users_latest_row(fake, fake_client):
    alice = lab_student(fake, fake_client)
    bob = fake.add_user("bob@example.edu")
    older = fake.add_note(alice, "older", 2)
    latest = fake.add_note(alice, "latest", 5)
    bobs = fake.add_note(bob, "bob", 9)
    response = act(fake_client, "delete")
    assert response.status_code == 200
    result = response.get_json()
    assert result["outcome"] == dict(OK, message=f"Deleted lab row #{latest}.")
    assert note_state(fake) == [(older, alice, "older", 2), (bobs, bob, "bob", 9)]
    (conn,) = fake.connections
    assert (lab.SQL["delete"], (latest, alice)) in conn.statements
    assert fake.writes == [(conn.id, alice, lab.SQL["delete"])]
    assert [n["note_id"] for n in result["notes"]] == [older]


@pytest.mark.parametrize("action", ["update", "delete", "rollback"])
def test_fake_actions_never_touch_another_users_row(fake, fake_client, action):
    lab_student(fake, fake_client)
    bob = fake.add_user("bob@example.edu")
    bobs = fake.add_note(bob, "bob", 9)
    response = act(fake_client, action, quantity=50)
    assert response.status_code == 409
    body = response.get_json()
    assert body["error"] == "lab" and "no lab row yet" in body["message"]
    assert note_state(fake) == [(bobs, bob, "bob", 9)] and fake.writes == []


def test_fake_violate_reports_the_check_violation_and_stores_nothing(fake, fake_client):
    lab_student(fake, fake_client)
    response = act(fake_client, "violate", label="Bad row")
    assert response.status_code == 200
    result = response.get_json()
    assert result["statement"] == lab.SQL["violate"]
    assert result["outcome"]["ok"] is False and result["outcome"]["error_code"] == 4025
    assert "ERROR 4025" in result["outcome"]["message"]
    (conn,) = fake.connections
    assert events_from(conn, lab.SQL["violate"])[1] == ("rollback",)
    assert fake.lab_notes == [] and fake.writes == []
    assert result["notes"] == [] and result["history"] == []


def test_fake_rollback_executes_the_update_and_undoes_it(fake, fake_client):
    uid = lab_student(fake, fake_client)
    note = fake.add_note(uid, "keep", 5)
    response = act(fake_client, "rollback", quantity=99)
    assert response.status_code == 200
    result = response.get_json()
    assert result["outcome"] == dict(OK, message="The UPDATE succeeded (1 row) and was rolled back: "
                                                 f"row #{note} still has quantity 5.")
    assert note_state(fake) == [(note, uid, "keep", 5)]
    (conn,) = fake.connections
    assert (lab.SQL["rollback"], (99, note, uid)) in conn.statements
    after = events_from(conn, lab.SQL["rollback"])
    assert after[1] == ("rollback",)
    assert after[2] == ("execute", "SELECT quantity FROM audit_lab_notes WHERE note_id = %s")
    # The statement ran as the student; it is in the log although it was rolled back.
    assert fake.writes == [(conn.id, uid, lab.SQL["rollback"])]
    assert fake.held_locks() == {}
    assert [(n["note_id"], n["quantity"]) for n in result["notes"]] == [(note, 5)]


def test_fake_denied_statement_is_refused_and_deletes_nothing(fake, fake_client):
    uid = lab_student(fake, fake_client)
    room = fake.add_room("Study Room")
    start = datetime.now() + timedelta(days=3)
    booking = fake.add_booking(uid, room, start, start + timedelta(hours=1))
    response = act(fake_client, "denied")
    assert response.status_code == 200
    result = response.get_json()
    assert result["statement"] == "DELETE FROM bookings WHERE booking_id = 0"
    assert result["outcome"]["ok"] is False and result["outcome"]["error_code"] == 1142
    assert "ERROR 1142" in result["outcome"]["message"]
    (conn,) = fake.connections
    assert events_from(conn, lab.SQL["denied"])[1] == ("rollback",)
    assert [(b["booking_id"], b["status"]) for b in fake.bookings] == [(booking, "confirmed")]
    assert fake.writes == []


def test_fake_failed_login_is_refused_for_the_decoy_account_only(fake, fake_client):
    lab_student(fake, fake_client)
    response = act(fake_client, "failed_login")
    assert response.status_code == 200
    result = response.get_json()
    assert result["statement"] is None
    assert result["outcome"] == {"ok": False, "error_code": 1045,
                                 "message": f"MariaDB refused the login of '{lab.INTRUDER_ACCOUNT}': ERROR 1045"}
    (attempt,) = fake.intruder_attempts
    assert (attempt["user"], attempt["host"], attempt["port"]) == (lab.INTRUDER_ACCOUNT, "fake-host", 3306)
    assert "database" not in attempt
    app_call, probe_call = fake.connect_calls
    assert app_call["user"] == "campus_app" and probe_call["user"] == lab.INTRUDER_ACCOUNT
    assert probe_call["password"] and probe_call["password"] != app_call["password"]
    # The request's own campus_app connection was not affected and went on working.
    (conn,) = fake.connections
    assert conn.kwargs["user"] == "campus_app" and result["connection_id"] == conn.id
    assert conn.executed(r"^CALL campus_audit\.import_current_log")
    assert result["plugin"]["imported"] is True and result["plugin"]["events"] == []      # fake: no records
    assert fake.writes == []
    with fake_client.session_transaction() as s:
        assert s["lab_journal"] == []


def test_fake_failed_login_reports_an_accepted_decoy_login(fake, fake_client):
    lab_student(fake, fake_client)
    fake.reject_intruder = False
    result = act(fake_client, "failed_login").get_json()
    assert result["outcome"]["ok"] is True and result["outcome"]["error_code"] is None
    assert "Unexpected" in result["outcome"]["message"]
    main, probe = fake.connections
    assert probe.kwargs["user"] == lab.INTRUDER_ACCOUNT and probe.closed and probe.statements == []
    assert main.kwargs["user"] == "campus_app"


def test_fake_action_without_csrf_token_never_reaches_the_database(fake, fake_client):
    uid = lab_student(fake, fake_client)
    note = fake.add_note(uid, "keep", 5)
    response = fake_client.post("/lab/api/action", json={"action": "delete"})
    assert response.status_code == 400 and response.get_json()["error"] == "csrf"
    wrong = fake_client.post("/lab/api/action", json={"action": "delete"}, headers={"X-CSRF-Token": "not-the-token"})
    assert wrong.status_code == 400 and wrong.get_json()["error"] == "csrf"
    assert fake.connections == [] and note_state(fake) == [(note, uid, "keep", 5)]


@pytest.mark.parametrize("action", sorted(lab.ACTIONS))
def test_fake_actions_are_refused_for_deactivated_accounts(fake, fake_client, action):
    uid = fake.add_user("gone@example.edu", active=False)
    login_as(fake_client, uid)
    note = fake.add_note(uid, "keep", 5)
    response = act(fake_client, action)
    assert response.status_code == 401 and response.get_json()["error"] == "login_required"
    assert note_state(fake) == [(note, uid, "keep", 5)]
    assert fake.writes == [] and fake.intruder_attempts == []
    with fake_client.session_transaction() as s:
        assert "user_id" not in s                                # the stale session ended


def test_fake_reset_removes_only_the_request_users_rows(fake, fake_client):
    alice = lab_student(fake, fake_client)
    bob = fake.add_user("bob@example.edu")
    fake.add_note(alice, "one", 1)
    bobs = fake.add_note(bob, "bob", 9)
    fake.add_note(alice, "two", 2)
    response = fake_client.post("/lab/api/reset", headers={"X-CSRF-Token": token(fake_client)})
    assert response.status_code == 200 and response.get_json() == {"removed": 2, "notes": []}
    assert note_state(fake) == [(bobs, bob, "bob", 9)]
    (conn,) = fake.connections
    assert fake.writes == [(conn.id, alice, lab.SQL["reset"])]
    assert fake.held_locks() == {}


def test_fake_notes_endpoint_lists_only_the_request_users_rows(fake, fake_client):
    alice = lab_student(fake, fake_client)
    bob = fake.add_user("bob@example.edu")
    mine = fake.add_note(alice, "mine", 3)
    fake.add_note(bob, "bob", 9)
    notes = fake_client.get("/lab/api/notes").get_json()["notes"]
    assert [(n["note_id"], n["label"], n["quantity"]) for n in notes] == [(mine, "mine", 3)]
    assert fake.writes == []


def test_fake_action_is_kept_when_the_plugin_log_cannot_be_imported(fake, fake_client):
    fake.plugin_installed = False
    uid = lab_student(fake, fake_client)
    response = act(fake_client, "create", label="Kept", quantity=2)
    assert response.status_code == 200
    result = response.get_json()
    assert result["outcome"]["ok"] is True
    assert result["plugin"]["imported"] is False and result["plugin"]["events"] == []
    assert "migration 003" in result["plugin"]["error"]
    assert "fake-app-password" not in response.get_data(as_text=True)
    (note,) = fake.lab_notes                                   # committed before the import failed
    assert (note["owner_user_id"], note["label"], note["quantity"]) == (uid, "Kept", 2)


# ---------------------------------------------------------------- with database

db_only = pytest.mark.skipif(os.getenv("RUN_DB_TESTS") != "1", reason="set RUN_DB_TESTS=1 to run against MariaDB")


def connect():
    return pymysql.connect(host=os.getenv("DB_HOST", "127.0.0.1"), port=int(os.getenv("DB_PORT", "3306")),
                           user=os.getenv("DB_USER", "campus_app"), password=os.getenv("DB_PASSWORD"),
                           database=os.getenv("DB_NAME", "university_resources"), autocommit=True)


def scalar(sql, args=()):
    with connect() as db, db.cursor() as cursor:
        cursor.execute(sql, args)
        row = cursor.fetchone()
        return row[0] if row else None


def user_id(email):
    return scalar("SELECT user_id FROM users WHERE email = %s", (email,))


def records(result, event_type=None, table=None):
    found = [e["record"] for e in result["plugin"]["events"]]
    if event_type:
        found = [r for r in found if r["event"] == event_type]
    if table:
        found = [r for r in found if r.get("table") == table]
    return found


@pytest.fixture()
def alice(client):
    login_as(client, user_id("alice.student@example.edu"))
    return client


@db_only
def test_healthz_ok():
    app = webapp.create_app({"TESTING": True, "SECRET_KEY": "x"})
    response = app.test_client().get("/healthz")
    assert response.status_code == 200 and response.get_json()["status"] == "ok"


@db_only
def test_wrong_application_password_gives_the_1045_explanation():
    """The situation of a volume initialised with an earlier .env: MariaDB answers ER 1045."""
    app = webapp.create_app({"TESTING": True, "SECRET_KEY": "x", "DB_PASSWORD": "not-the-password"})
    c = app.test_client()
    response = c.post("/login", data={"email": "a@b.cd", "password": "x", "csrf_token": token(c)})
    assert response.status_code == 503
    assert b"MariaDB error 1045" in response.data and b"repair-credentials" in response.data


@db_only
def test_plugin_state_is_read_from_the_server(alice):
    data = alice.get("/lab/api/plugin").get_json()
    assert data["active"] is True
    assert data["plugin"]["PLUGIN_TYPE"] == "AUDIT" and data["plugin"]["PLUGIN_STATUS"] == "ACTIVE"
    assert data["status"]["campus_audit_state"] == "ACTIVE"
    assert "university_resources" in data["variables"]["campus_audit_databases"]
    assert data["import_available"] is True


@db_only
def test_insert_shows_plugin_records_and_trigger_row(alice):
    label = f"lab-secret-{random.randint(0, 10**9)}"
    response = act(alice, "create", label=label, quantity=4)
    assert response.status_code == 200
    result = response.get_json()
    assert result["outcome"]["ok"] and result["plugin"]["imported"]
    writes = records(result, "table_write")
    assert {r["table"] for r in writes} == {"audit_lab_notes", "audit_events"}       # the trigger's write too
    assert len({r["query_id"] for r in writes}) == 1                                  # one statement
    (statement,) = records(result, "statement")
    assert statement["error_code"] == 0 and statement["query_id"] == writes[0]["query_id"]
    assert statement["sql_digest"] == "INSERT INTO audit_lab_notes (owner_user_id, label, quantity) VALUES (?, ?, ?)"
    assert all(r["conn"] == result["connection_id"] for r in records(result))
    assert label not in json.dumps(result["plugin"]["events"])                      # literal masked
    (row,) = result["history"]
    assert row["action"] == "INSERT" and row["new_values"]["label"] == label           # but kept by the trigger
    assert row["application_user_id"] == user_id("alice.student@example.edu")
    assert row["event_source"] == "application" and row["connection_id"] == result["connection_id"]


@db_only
def test_check_violation_is_seen_by_the_plugin_only(alice):
    result = act(alice, "violate").get_json()
    assert result["outcome"]["ok"] is False and result["outcome"]["error_code"] == 4025
    assert records(result, "table_write", "audit_lab_notes")                          # opened before it failed
    (statement,) = records(result, "statement")
    assert statement["error_code"] == 4025 and statement["status"] == "error"
    assert result["history"] == []                                                    # no row, no trigger row


@db_only
def test_rollback_looks_successful_to_the_plugin(alice):
    act(alice, "create", quantity=5)
    result = act(alice, "rollback", quantity=99).get_json()
    (statement,) = records(result, "statement")
    assert statement["error_code"] == 0 and statement["status"] == "ok"
    assert result["history"] == []                                                    # rolled back with the change
    latest = scalar("SELECT quantity FROM audit_lab_notes WHERE owner_user_id = %s ORDER BY note_id DESC LIMIT 1",
                    (user_id("alice.student@example.edu"),))
    assert latest == 5


@db_only
def test_update_and_delete_history_keeps_old_values(alice):
    act(alice, "create", quantity=6)
    updated = act(alice, "update", quantity=7).get_json()
    (row,) = updated["history"]
    assert row["action"] == "UPDATE" and row["old_values"]["quantity"] == 6 and row["new_values"]["quantity"] == 7
    deleted = act(alice, "delete").get_json()
    (row,) = deleted["history"]
    assert row["action"] == "DELETE" and row["old_values"]["quantity"] == 7 and row["new_values"] is None
    assert records(deleted, "statement")[0]["sql_digest"].startswith("DELETE FROM audit_lab_notes")


@db_only
def test_refused_statement_has_no_table_event_but_a_statement_record(alice):
    result = act(alice, "denied").get_json()
    assert result["outcome"]["error_code"] == 1142
    assert records(result, "table_write") == []                                       # never opened
    (statement,) = records(result, "statement")
    assert statement["error_code"] == 1142 and statement["access_denied"] is True
    assert result["history"] == []
    assert scalar("SELECT COUNT(*) FROM bookings") > 0                                # nothing deleted


@db_only
def test_failed_database_login_is_a_connection_event(alice):
    result = act(alice, "failed_login").get_json()
    assert result["outcome"]["error_code"] == 1045
    failed = records(result, "connect_failed")
    assert failed and failed[-1]["user"] == lab.INTRUDER_ACCOUNT and failed[-1]["status"] == 1045


@db_only
def test_lab_rows_are_private_to_their_owner(client):
    alice_id, bob_id = user_id("alice.student@example.edu"), user_id("bob.student@example.edu")
    login_as(client, alice_id)
    act(client, "create", quantity=8)
    alice_note = scalar("SELECT MAX(note_id) FROM audit_lab_notes WHERE owner_user_id = %s", (alice_id,))
    login_as(client, bob_id)
    client.post("/lab/api/reset", headers={"X-CSRF-Token": token(client)})
    assert act(client, "update", quantity=50).status_code == 409                    # Bob has no row of his own
    assert act(client, "delete").status_code == 409
    assert scalar("SELECT quantity FROM audit_lab_notes WHERE note_id = %s", (alice_note,)) == 8


@db_only
def test_students_explore_only_their_own_records(client, flask_app):
    login_as(client, user_id("bob.student@example.edu"))
    own = act(client, "create", quantity=2).get_json()
    other = flask_app.test_client()
    login_as(other, user_id("alice.student@example.edu"))
    act(other, "create", quantity=2)
    mine = client.get("/lab/api/events?since=all&scope=all").get_json()                 # scope=all is admin-only
    assert mine["scope"] == "mine" and mine["events"]
    assert {e["connection_id"] for e in mine["events"]} <= {own["connection_id"]}
    history = client.get("/lab/api/history?since=all").get_json()["history"]
    assert history and all(r["application_user_id"] == user_id("bob.student@example.edu") for r in history)


@pytest.mark.skipif(not os.getenv("TEST_ADMIN_EMAIL"), reason="no local bootstrap administrator")
@db_only
def test_administrators_can_explore_every_record(client):
    # The seed's dana.admin is demoted by migration 004; the role is checked in the database.
    login_as(client, user_id(os.environ["TEST_ADMIN_EMAIL"]), "admin")
    client.post("/lab/api/import", headers={"X-CSRF-Token": token(client)})
    data = client.get("/lab/api/events?since=all&scope=all").get_json()
    assert data["scope"] == "all" and len({e["connection_id"] for e in data["events"]}) > 1
    filtered = client.get("/lab/api/events?since=all&scope=all&type=statement&outcome=error").get_json()
    assert filtered["events"] and all(e["event_type"] == "statement" and e["status_code"] != 0
                                      for e in filtered["events"])


@db_only
def test_application_account_cannot_import_arbitrary_files():
    with connect() as db, db.cursor() as cursor:
        cursor.execute("SELECT LOAD_FILE(@@GLOBAL.campus_audit_file_path) IS NULL")
        assert cursor.fetchone()[0] == 1                                               # no FILE privilege
        with pytest.raises(pymysql.err.OperationalError) as denied:
            cursor.execute("CALL campus_audit.import_plugin_log('/etc/passwd')")
        assert denied.value.args[0] == 1370                                            # only import_current_log()

# The login ?next= allow-list is tested without a server in test_app.py
# (test_login_next_parameter_is_allow_listed); the seed has no usable passwords.
