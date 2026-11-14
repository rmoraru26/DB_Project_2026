"""Tests for the Smart Campus web application.

Three groups:

* no database at all (configuration, booking rules, CSRF, throttling);
* the in-memory fake database of tests/fakedb.py (request lifecycle,
  attribution, transactions, locking, cancellation, grant contract);
* a real MariaDB server with schema, migrations, triggers and seed data,
  skipped unless RUN_DB_TESTS=1.  It connects as the application account
  (DB_HOST, DB_PORT, DB_USER, DB_PASSWORD), exactly like the app does.
"""
import json
import os
import pathlib
import random
import re
import threading
import time
from datetime import date, datetime, timedelta

import flask
import pymysql
import pytest

os.environ.setdefault("SECRET_KEY", "test-only-secret-key")

import app as webapp  # noqa: E402
from fakedb import form_post, session_token, sign_in  # noqa: E402

FRONTEND = pathlib.Path(webapp.__file__).parent


@pytest.fixture()
def flask_app():
    """No database configured: reaching get_db() answers 503 without connecting."""
    return webapp.create_app({"TESTING": True, "SECRET_KEY": "test-only-secret-key",
                              "DB_USER": "campus_app", "DB_PASSWORD": None})


@pytest.fixture()
def client(flask_app):
    return flask_app.test_client()


login_as = sign_in
post = form_post
csrf_token_of = session_token


def tomorrow_at(hour):
    return datetime.combine(date.today() + timedelta(days=1), datetime.min.time()).replace(hour=hour)


def slot(start):
    return f"{start.hour:02d}:00 - {start.hour + 1:02d}:00"


# ================================================================ configuration (no database)

def test_missing_secret_key_is_refused(monkeypatch):
    monkeypatch.delenv("SECRET_KEY", raising=False)
    with pytest.raises(RuntimeError):
        webapp.create_app({"SECRET_KEY": None})


def test_placeholder_secret_key_is_refused():
    with pytest.raises(RuntimeError):
        webapp.create_app({"SECRET_KEY": "change-me-flask-secret-key"})


def test_root_database_account_is_refused():
    with pytest.raises(RuntimeError, match="campus_app"):
        webapp.create_app({"SECRET_KEY": "x", "DB_USER": "root"})


def test_default_database_account_is_campus_app(monkeypatch):
    monkeypatch.delenv("DB_USER", raising=False)
    assert webapp.create_app({"SECRET_KEY": "x"}).config["DB_USER"] == "campus_app"


def test_exact_application_account_is_accepted_and_used(fake):
    app = webapp.create_app({"TESTING": True, "SECRET_KEY": "x", "DB_USER": "campus_app",
                             "DB_PASSWORD": "password-of-the-fake"})
    assert app.test_client().get("/healthz").status_code == 200
    (call,) = fake.connect_calls
    assert call["user"] == "campus_app" and call["password"] == "password-of-the-fake"


@pytest.mark.parametrize("account", [
    "root", "ROOT", "admin", "campus_admin", "mariadb.sys", "backup_operator", "db_maintenance",
    "campus_app_admin", "Campus_App", " campus_app", "campus_app ", "campus_app@localhost", "", None])
def test_any_other_database_account_is_refused_before_connecting(fake, account):
    """Not only root: administrators, maintenance accounts, arbitrary and empty names."""
    with pytest.raises(RuntimeError, match="campus_app"):
        webapp.create_app({"SECRET_KEY": "x", "DB_USER": account, "DB_PASSWORD": "password-of-the-fake"})
    assert fake.connect_calls == []


@pytest.mark.parametrize("value", ["root", "db_maintenance", ""])
def test_database_account_from_the_environment_is_checked_too(monkeypatch, fake, value):
    monkeypatch.setenv("DB_USER", value)
    with pytest.raises(RuntimeError, match="campus_app"):
        webapp.create_app({"SECRET_KEY": "x", "DB_PASSWORD": "password-of-the-fake"})
    assert fake.connect_calls == []


def test_account_changed_after_startup_is_refused_without_connecting(fake, fake_app):
    fake_app.config["DB_USER"] = "root"
    c = fake_app.test_client()
    login_as(c, 1)
    assert c.get("/healthz").status_code == 503
    page = c.get("/accountProfile")
    assert page.status_code == 503 and b"cannot reach its database" in page.data
    assert fake.connect_calls == []


def test_runtime_configuration_holds_no_privileged_credentials(monkeypatch, fake):
    """Operator variables in the environment (seed.py, scripts/) never reach the web app."""
    monkeypatch.setenv("DB_ADMIN_USER", "root")
    monkeypatch.setenv("MYSQL_PWD", "operator-secret-1")
    monkeypatch.setenv("MARIADB_ROOT_PASSWORD", "root-secret-2")
    app = webapp.create_app({"TESTING": True, "SECRET_KEY": "x", "DB_USER": "campus_app",
                             "DB_PASSWORD": "password-of-the-fake"})
    assert not {"DB_ADMIN_USER", "MYSQL_PWD", "MARIADB_ROOT_PASSWORD"} & set(app.config)
    values = [str(v) for v in app.config.values()]
    assert "operator-secret-1" not in values and "root-secret-2" not in values and "root" not in values
    assert app.test_client().get("/healthz").status_code == 200
    (call,) = fake.connect_calls
    assert call["user"] == "campus_app" and call["password"] == "password-of-the-fake"


def test_app_source_reads_no_operator_credentials():
    source = (FRONTEND / "app.py").read_text(encoding="utf-8") + (FRONTEND / "lab.py").read_text(encoding="utf-8")
    for name in ("DB_ADMIN_USER", "MYSQL_PWD", "MARIADB_ROOT_PASSWORD", "get_db_connection"):
        assert name not in source


def test_entrypoints_stay_importable():
    """`python app.py`, `flask --app app` and `from app import app` keep working."""
    assert callable(webapp.create_app)
    from flask import Flask
    assert isinstance(webapp.app, Flask)
    assert webapp.app is webapp.app                      # one default instance
    # The seed-only connection helper is gone: frontend/seed.py connects on its
    # own with explicit maintenance credentials (tests/test_seed.py).
    assert not hasattr(webapp, "get_db_connection")


def test_session_cookie_is_httponly_and_samesite(client):
    cookie = client.get("/login").headers.get("Set-Cookie", "")
    assert "HttpOnly" in cookie and "SameSite=Lax" in cookie
    assert "Secure" not in cookie                       # plain-HTTP development keeps working


def test_secure_cookie_when_https_is_configured(monkeypatch):
    monkeypatch.setenv("SESSION_COOKIE_SECURE", "1")
    app = webapp.create_app({"TESTING": True, "SECRET_KEY": "x"})
    assert app.config["SESSION_COOKIE_SECURE"] is True
    assert app.config["PERMANENT_SESSION_LIFETIME"] <= timedelta(hours=12)


# ================================================================ official booking rules (no database)

NOW = datetime(2026, 11, 12, 8, 30)


def test_official_slots_run_from_0900_to_2200():
    assert webapp.SLOT_LABELS[0] == "09:00 - 10:00"
    assert webapp.SLOT_LABELS[-1] == "21:00 - 22:00"
    assert len(webapp.SLOT_LABELS) == 13


@pytest.mark.parametrize("label", ["09:00 - 10:00", "21:00 - 22:00"])
def test_first_and_last_slot_are_bookable(label):
    start, end = webapp.check_booking_rules("room", "2026-11-13", label, now=NOW)
    assert (start, end) == (datetime(2026, 11, 13, int(label[:2])), datetime(2026, 11, 13, int(label[:2]) + 1))


@pytest.mark.parametrize("label", ["08:00 - 09:00", "22:00 - 23:00", "09:00 - 15:00", "10:00 - 09:00",
                                   "'; DROP TABLE bookings; --", None, ""])
def test_slots_outside_the_official_hours_are_rejected(label):
    with pytest.raises(webapp.BookingError):
        webapp.check_booking_rules("room", "2026-11-13", label, now=NOW)


@pytest.mark.parametrize("day", ["not-a-date", None, "2026-13-01"])
def test_invalid_dates_are_rejected(day):
    with pytest.raises(webapp.BookingError, match="valid date"):
        webapp.check_booking_rules("item", day, "10:00 - 11:00", now=NOW)


def test_past_slots_are_rejected():
    with pytest.raises(webapp.BookingError, match="past"):
        webapp.check_booking_rules("item", "2026-11-12", "09:00 - 10:00", now=datetime(2026, 11, 12, 9, 30))


def test_item_horizon_is_today_through_14_days():
    webapp.check_booking_rules("item", "2026-11-12", "09:00 - 10:00", now=NOW)        # today
    webapp.check_booking_rules("item", "2026-11-26", "21:00 - 22:00", now=NOW)        # +14 days
    with pytest.raises(webapp.BookingError, match="14 days"):
        webapp.check_booking_rules("item", "2026-11-27", "09:00 - 10:00", now=NOW)


def test_room_horizon_is_three_calendar_months():
    webapp.check_booking_rules("room", "2027-02-12", "09:00 - 10:00", now=NOW)        # +3 months
    with pytest.raises(webapp.BookingError, match="3 months"):
        webapp.check_booking_rules("room", "2027-02-13", "09:00 - 10:00", now=NOW)


def test_room_horizon_clamps_to_month_end():
    assert webapp.add_months(date(2026, 11, 30), 3) == date(2027, 2, 28)
    assert webapp.last_bookable_date("room", date(2027, 1, 31)) == date(2027, 4, 30)
    assert webapp.last_bookable_date("item", date(2026, 11, 12)) == date(2026, 11, 26)


# ================================================================ routes and authorization (no database)

OFFICIAL_ROUTES = {
    "/": "index",
    "/lab": "lab",
    "/accountProfile": "account_profile",
    "/accountBookings": "account_bookings",
    "/accountSettings": "account_settings",
    "/login": "login",
    "/logout": "logout",
    "/register": "register",
    "/itemsHome": "items_home",
    "/items/<item_name>": "item_booking",
    "/items/<item_name>/verifyBooking": "verify_item_booking",
    "/items/<item_name>/confirmBooking": "confirm_item_booking",
    "/roomsHome": "rooms_home",
    "/rooms/<room_name>": "room_booking",
    "/rooms/<room_name>/verifyBooking": "verify_room_booking",
    "/rooms/<room_name>/confirmBooking": "confirm_room_booking",
    "/cancelBooking": "cancel_booking",
}


def test_official_routes_and_endpoint_names_are_kept(flask_app):
    rules = {r.rule: r.endpoint for r in flask_app.url_map.iter_rules()}
    for rule, endpoint in OFFICIAL_ROUTES.items():
        assert rules.get(rule) == endpoint, rule
    # Named resources, not the staging numeric ids.
    assert "/items/<int:item_id>" not in rules and "/rooms/<int:room_id>" not in rules
    with flask_app.test_request_context():
        from flask import url_for
        assert url_for("item_booking", item_name="Settlers of Catan") == "/items/Settlers%20of%20Catan"
        assert url_for("confirm_room_booking", room_name="Study Room") == "/rooms/Study%20Room/confirmBooking"


@pytest.mark.parametrize("path", ["/roomsHome", "/itemsHome", "/accountProfile", "/accountBookings",
                                  "/accountSettings", "/admin/audit", "/rooms/Study%20Room", "/items/Chess"])
def test_pages_require_login(client, path):
    response = client.get(path)
    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_admin_page_forbidden_for_students(client):
    login_as(client, 1, "student")
    assert client.get("/admin/audit").status_code == 403


@pytest.mark.parametrize("form,message", [
    ({"full_name": "", "email": "a@b.cd", "password": "longenough", "confirm_password": "longenough"}, b"name"),
    ({"full_name": "A", "email": "not-an-email", "password": "longenough", "confirm_password": "longenough"},
     b"valid email"),
    ({"full_name": "A", "email": "a@b.cd", "password": "short", "confirm_password": "short"}, b"8 characters"),
    ({"full_name": "A", "email": "a@b.cd", "password": "longenough", "confirm_password": "different1"},
     b"do not match"),
])
def test_register_validation_happens_before_database_access(client, form, message):
    response = post(client, "/register", data=form)
    assert response.status_code == 400
    assert message in response.data


# ================================================================ CSRF (no database)

POST_ROUTES = ["/login", "/register", "/logout", "/accountSettings", "/cancelBooking",
               "/rooms/Study%20Room/verifyBooking", "/rooms/Study%20Room/confirmBooking",
               "/items/Chess/verifyBooking", "/items/Chess/confirmBooking",
               "/lab/api/action", "/lab/api/import", "/lab/api/reset"]


@pytest.mark.parametrize("path", POST_ROUTES)
def test_post_without_csrf_token_is_rejected(client, path):
    login_as(client, 1, "student")           # even a logged-in user needs the token
    response = client.post(path, data={"email": "a@b.cd", "password": "x"})
    assert response.status_code == 400
    assert b"CSRF" in response.data or b"csrf" in response.data


def test_post_with_wrong_csrf_token_is_rejected(client):
    csrf_token_of(client)
    response = client.post("/register", data={"csrf_token": "not-the-token", "full_name": "A"})
    assert response.status_code == 400 and b"CSRF" in response.data


def test_csrf_token_of_another_session_is_rejected(flask_app):
    victim, attacker = flask_app.test_client(), flask_app.test_client()
    stolen = csrf_token_of(attacker)          # the attacker's own valid token
    csrf_token_of(victim)
    response = victim.post("/register", data={"csrf_token": stolen, "full_name": "A"})
    assert response.status_code == 400 and b"CSRF" in response.data


def test_csrf_token_in_header_is_accepted(client):
    token = csrf_token_of(client)
    response = client.post("/register", data={"full_name": ""}, headers={"X-CSRF-Token": token})
    assert response.status_code == 400 and b"name" in response.data and b"CSRF" not in response.data


@pytest.mark.parametrize("path", ["/login", "/register"])
def test_rendered_forms_carry_the_session_token(client, path):
    page = client.get(path)
    with client.session_transaction() as s:
        token = s["_csrf"]
    assert f'name="csrf_token" value="{token}"'.encode() in page.data


def test_every_post_form_template_contains_the_token_field():
    """Guards against adding a form later and forgetting the hidden field."""
    templates = FRONTEND / "templates"
    forms = 0
    for template in templates.rglob("*.html"):
        text = template.read_text(encoding="utf-8")
        for form in re.findall(r'<form[^>]*method="(?:POST|post)"[^>]*>(.*?)</form>', text, flags=re.S):
            forms += 1
            assert 'name="csrf_token"' in form, f"{template.name}: POST form without csrf_token"
    assert forms >= 9


def test_every_mutating_fetch_sends_the_csrf_header():
    for script in (FRONTEND / "static").glob("*.js"):
        text = script.read_text(encoding="utf-8")
        if "fetch(" in text:
            assert 'headers["X-CSRF-Token"] = csrf' in text, script.name
            assert text.count("fetch(") == 1, f"{script.name}: every request must go through api()"


# ================================================================ login throttle (no database)

def test_login_throttle_blocks_after_repeated_failures_and_recovers():
    now = [0.0]
    throttle = webapp.LoginThrottle(max_failures=3, window_seconds=60, clock=lambda: now[0])
    key = ("127.0.0.1", "a@b.cd")
    for _ in range(2):
        throttle.record_failure(key)
    assert not throttle.blocked(key)
    throttle.record_failure(key)
    assert throttle.blocked(key)
    assert not throttle.blocked(("127.0.0.1", "other@b.cd"))   # per account
    now[0] = 61.0                                               # window passed
    assert not throttle.blocked(key)
    throttle.record_failure(key)
    throttle.record_failure(key)
    throttle.record_failure(key)
    throttle.clear(key)                                         # successful login
    assert not throttle.blocked(key)


def test_login_is_refused_with_429_before_any_database_access(flask_app, client):
    key = ("127.0.0.1", "alice.student@example.edu")
    for _ in range(flask_app.login_throttle.max_failures):
        flask_app.login_throttle.record_failure(key)
    # No database is configured for this test: reaching get_db() would answer 503.
    response = post(client, "/login", data={"email": "alice.student@example.edu", "password": "x"},
                    environ_overrides={"REMOTE_ADDR": "127.0.0.1"})
    assert response.status_code == 429
    assert b"Too many failed attempts" in response.data


def test_login_throttle_policy_of_the_application(flask_app):
    pair, address, lab = flask_app.login_throttle, flask_app.login_ip_throttle, flask_app.lab_throttle
    assert (pair.max_failures, pair.window) == (5, 300)
    assert (address.max_failures, address.window) == (60, 300)
    assert (lab.max_failures, lab.window) == (60, 300)         # the Audit Lab's limit is unchanged
    assert pair is not address and address is not lab          # separate stores: one cannot crowd out another
    assert pair.max_entries == address.max_entries == lab.max_entries == webapp.THROTTLE_MAX_ENTRIES


def test_login_throttle_counts_only_failures_inside_the_rolling_window():
    now = [0.0]
    throttle = webapp.LoginThrottle(max_failures=3, window_seconds=60, clock=lambda: now[0])
    for at in (0.0, 30.0, 50.0):
        now[0] = at
        throttle.record_failure("k")
    assert throttle.blocked("k")
    now[0] = 60.0                                               # the first failure is exactly one window old
    assert throttle.blocked("k")
    now[0] = 61.0                                               # only the failures at 30 and 50 still count
    assert not throttle.blocked("k")
    throttle.record_failure("k")
    assert throttle.blocked("k")
    now[0] = 200.0
    assert not throttle.blocked("k") and len(throttle) == 0


def test_login_throttle_removes_expired_keys_that_are_never_checked_again():
    now = [0.0]
    throttle = webapp.LoginThrottle(max_failures=3, window_seconds=60, clock=lambda: now[0])
    for n in range(50):
        throttle.record_failure(("203.0.113.9", f"user{n}@example.edu"))
    now[0] = 30.0
    throttle.record_failure("still-recent")
    assert len(throttle) == 51
    now[0] = 61.0                                               # the 50 keys are expired; none is asked about again
    throttle.record_failure("another-key")
    assert len(throttle) == 2
    now[0] = 91.0                                               # a check of an unrelated key prunes as well
    assert not throttle.blocked("unrelated")
    assert len(throttle) == 1
    now[0] = 1000.0
    assert not throttle.blocked("unrelated") and len(throttle) == 0


def test_login_throttle_never_stores_more_than_max_entries():
    now = [0.0]
    throttle = webapp.LoginThrottle(max_failures=3, window_seconds=60, clock=lambda: now[0], max_entries=10)
    assert throttle.max_entries == 10
    for _ in range(3):
        throttle.record_failure("guessed-account")
    for n in range(1000):                                       # all inside one window: nothing expires
        throttle.record_failure(("unique", n))
        assert len(throttle) <= 10
        if n % 5 == 0:
            throttle.record_failure("guessed-account")          # still failing: stays among the newest keys
    assert len(throttle) == 10
    assert throttle.blocked("guessed-account")                  # the least recently failed keys were dropped, not this
    assert not throttle.blocked(("unique", 0))
    # The history of one key is bounded too.
    for _ in range(1000):
        throttle.record_failure("guessed-account")
    assert len(throttle._failures["guessed-account"]) == 3
    with pytest.raises(ValueError):
        webapp.LoginThrottle(max_entries=0)


def test_login_throttle_survives_concurrent_updates():
    threads, rounds = 8, 300
    counting = webapp.LoginThrottle(max_failures=threads * rounds, window_seconds=60, clock=lambda: 0.0)
    churning = webapp.LoginThrottle(max_failures=3, window_seconds=60, clock=lambda: 0.0, max_entries=16)
    start, errors = threading.Barrier(threads), []

    def work(worker):
        try:
            start.wait(timeout=10)
            for n in range(rounds):
                counting.record_failure("shared")
                counting.record_failure(("own", worker))
                counting.blocked("shared")
                churning.record_failure((worker, n))
                churning.record_failure("shared")
                churning.blocked((worker, n - 1))
                churning.clear((worker, n - 2))
                assert len(churning) <= 16
        except Exception as error:                              # noqa: BLE001 - reported by the assert below
            errors.append(error)

    workers = [threading.Thread(target=work, args=(w,)) for w in range(threads)]
    for t in workers:
        t.start()
    for t in workers:
        t.join(timeout=60)
    assert errors == [] and not any(t.is_alive() for t in workers)
    # No update was lost: exactly threads * rounds failures are needed to block "shared".
    assert counting.blocked("shared") and len(counting._failures["shared"]) == threads * rounds
    assert all(len(counting._failures[("own", w)]) == rounds for w in range(threads))
    assert not any(counting.blocked(("own", w)) for w in range(threads))
    assert len(counting) == threads + 1
    assert 1 <= len(churning) <= 16 and churning.blocked("shared")
    assert all(1 <= len(recent) <= 3 for recent in churning._failures.values())


# ================================================================ authentication (fake database)

PASSWORD = "correct-horse-battery"


def test_successful_login_stores_id_and_role(fake, fake_client):
    uid = fake.add_user("ada@example.edu", role="student")
    response = post(fake_client, "/login", data={"email": "ada@example.edu", "password": PASSWORD})
    assert response.status_code == 302 and response.headers["Location"].endswith("/")
    with fake_client.session_transaction() as s:
        assert s["user_id"] == uid and s["role"] == "student"


def test_login_rotates_the_session(fake, fake_client):
    fake.add_user("ada@example.edu")
    with fake_client.session_transaction() as s:
        s["_csrf"] = "pre-login-token"
        s["lab_journal"] = [[1, "2026-11-12 10:00:00"]]
        s["planted"] = "attacker value"
    response = fake_client.post("/login", data={"email": "ada@example.edu", "password": PASSWORD,
                                                "csrf_token": "pre-login-token"})
    assert response.status_code == 302                       # validated with the pre-login token ...
    with fake_client.session_transaction() as s:
        assert "planted" not in s and "lab_journal" not in s  # ... then everything old is dropped
        assert s["_csrf"] and s["_csrf"] != "pre-login-token"
    # The old token no longer works after the authentication boundary.
    stale = fake_client.post("/logout", data={"csrf_token": "pre-login-token"})
    assert stale.status_code == 400


@pytest.mark.parametrize("email,password", [("ada@example.edu", "wrong-password"),
                                            ("nobody@example.edu", PASSWORD)])
def test_invalid_login_gives_one_generic_answer(fake, fake_client, email, password):
    fake.add_user("ada@example.edu")
    response = post(fake_client, "/login", data={"email": email, "password": password})
    assert response.status_code == 401
    assert b"Invalid email or password" in response.data
    with fake_client.session_transaction() as s:
        assert "user_id" not in s


def test_inactive_account_cannot_log_in(fake, fake_client):
    fake.add_user("gone@example.edu", active=False)
    response = post(fake_client, "/login", data={"email": "gone@example.edu", "password": PASSWORD})
    assert response.status_code == 401 and b"Invalid email or password" in response.data
    with fake_client.session_transaction() as s:
        assert "user_id" not in s


def test_deactivated_account_loses_its_session(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid)
    assert fake_client.get("/itemsHome").status_code == 200
    fake.users[uid]["is_active"] = 0
    response = fake_client.get("/itemsHome")
    assert response.status_code == 302 and "/login" in response.headers["Location"]
    with fake_client.session_transaction() as s:
        assert "user_id" not in s


def test_login_throttle_is_the_same_for_known_and_unknown_emails(fake, fake_app):
    fake.add_user("ada@example.edu")
    for email in ("ada@example.edu", "nobody@example.edu"):
        c = fake_app.test_client()
        codes = [post(c, "/login", data={"email": email, "password": "wrong"}).status_code
                 for _ in range(fake_app.login_throttle.max_failures + 1)]
        assert codes == [401] * fake_app.login_throttle.max_failures + [429], email


def test_successful_login_clears_the_failure_count(fake, fake_app):
    fake.add_user("ada@example.edu")
    c = fake_app.test_client()
    for _ in range(fake_app.login_throttle.max_failures - 1):
        post(c, "/login", data={"email": "ada@example.edu", "password": "wrong"})
    assert post(c, "/login", data={"email": "ada@example.edu", "password": PASSWORD}).status_code == 302
    assert not fake_app.login_throttle.blocked(("127.0.0.1", "ada@example.edu"))


def test_login_failures_of_one_email_do_not_count_for_another_email(fake, fake_app):
    fake.add_user("ada@example.edu")
    c = fake_app.test_client()
    for _ in range(fake_app.login_throttle.max_failures):
        assert post(c, "/login", data={"email": "ada@example.edu", "password": "wrong"}).status_code == 401
    assert post(c, "/login", data={"email": "ada@example.edu", "password": PASSWORD}).status_code == 429
    assert post(c, "/login", data={"email": "bob@example.edu", "password": "wrong"}).status_code == 401


def test_login_ip_limit_counts_failures_across_different_emails(fake, fake_app):
    fake.add_user("ada@example.edu")
    c = fake_app.test_client()
    limit = fake_app.login_ip_throttle.max_failures
    assert limit == 60
    # 20 emails, 3 failures each: no pair comes near its own limit of 5.  A
    # different X-Forwarded-For value on every request changes nothing.
    for n in range(limit):
        response = post(c, "/login", data={"email": f"user{n % 20}@example.edu", "password": "wrong"},
                        headers={"X-Forwarded-For": f"198.51.100.{n}"})
        assert response.status_code == 401, n
    assert not any(fake_app.login_throttle.blocked(("127.0.0.1", f"user{n}@example.edu")) for n in range(20))
    assert fake_app.login_ip_throttle.blocked("127.0.0.1")
    assert len(fake_app.login_ip_throttle) == 1                 # one bucket for the address, not one per header value
    # The next attempt is refused before the database: a new email, and the right password as well.
    connections = len(fake.connections)
    refused = post(c, "/login", data={"email": "fresh@example.edu", "password": "wrong"},
                   headers={"X-Forwarded-For": "198.51.100.200"})
    assert refused.status_code == 429 and b"Too many failed attempts" in refused.data
    assert post(c, "/login", data={"email": "ada@example.edu", "password": PASSWORD}).status_code == 429
    assert len(fake.connections) == connections
    # Another address has its own counter.
    elsewhere = {"REMOTE_ADDR": "192.0.2.7"}
    other = fake_app.test_client()
    assert post(other, "/login", data={"email": "fresh@example.edu", "password": "wrong"},
                environ_overrides=elsewhere).status_code == 401
    assert post(other, "/login", data={"email": "ada@example.edu", "password": PASSWORD},
                environ_overrides=elsewhere).status_code == 302


def test_successful_login_keeps_the_failure_history_of_the_address(fake, fake_app):
    fake.add_user("ada@example.edu")
    c = fake_app.test_client()
    limit = fake_app.login_ip_throttle.max_failures
    for _ in range(limit - 4):                                  # earlier failures from this address
        fake_app.login_ip_throttle.record_failure("127.0.0.1")
    for _ in range(3):
        assert post(c, "/login", data={"email": "ada@example.edu", "password": "wrong"}).status_code == 401
    assert post(c, "/login", data={"email": "ada@example.edu", "password": PASSWORD}).status_code == 302
    assert ("127.0.0.1", "ada@example.edu") not in fake_app.login_throttle._failures      # the pair is cleared ...
    assert len(fake_app.login_ip_throttle._failures["127.0.0.1"]) == limit - 1            # ... the address is not
    fresh = fake_app.test_client()
    assert post(fresh, "/login", data={"email": "bob@example.edu", "password": "wrong"}).status_code == 401
    assert post(fresh, "/login", data={"email": "ada@example.edu", "password": PASSWORD}).status_code == 429


def test_login_limits_expire_with_the_window(fake, fake_app):
    fake.add_user("ada@example.edu")
    now = [0.0]
    fake_app.login_throttle = webapp.LoginThrottle(max_failures=5, window_seconds=300, clock=lambda: now[0])
    fake_app.login_ip_throttle = webapp.LoginThrottle(max_failures=60, window_seconds=300, clock=lambda: now[0])
    c = fake_app.test_client()
    form = {"email": "ada@example.edu", "password": PASSWORD}
    for _ in range(5):
        fake_app.login_throttle.record_failure(("127.0.0.1", "ada@example.edu"))
    assert post(c, "/login", data=form).status_code == 429     # the pair
    now[0] = 301.0
    for _ in range(60):
        fake_app.login_ip_throttle.record_failure("127.0.0.1")
    assert post(c, "/login", data=form).status_code == 429     # the pair has expired, the address is blocked
    now[0] = 601.0
    assert post(c, "/login", data=form).status_code == 429     # exactly one window later: still counted
    now[0] = 602.0
    assert post(c, "/login", data=form).status_code == 302


def test_login_throttle_key_has_a_bounded_size(fake, fake_app):
    c = fake_app.test_client()
    response = post(c, "/login", data={"email": "A" * 5000 + "@example.edu", "password": "wrong"})
    assert response.status_code == 401
    assert list(fake_app.login_throttle._failures) == [("127.0.0.1", "a" * 254)]


def test_login_next_parameter_is_allow_listed(fake, fake_client):
    fake.add_user("ada@example.edu")
    form = {"email": "ada@example.edu", "password": PASSWORD}
    assert post(fake_client, "/login?next=lab", data=form).headers["Location"].endswith("/lab")
    assert post(fake_client, "/login?next=https://evil.example", data=form).headers["Location"].endswith("/")


def test_logout_requires_post_with_token(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid)
    assert fake_client.get("/logout").status_code == 405
    assert fake_client.post("/logout").status_code == 400
    with fake_client.session_transaction() as s:
        assert s["user_id"] == uid                           # a forged logout changes nothing
    response = post(fake_client, "/logout")
    assert response.status_code == 302
    with fake_client.session_transaction() as s:
        assert "user_id" not in s


def test_profile_page_has_a_post_logout_form(fake, fake_client):
    uid = fake.add_user("ada@example.edu", name="Ada Lovelace")
    login_as(fake_client, uid)
    html = fake_client.get("/accountProfile").data.decode()
    assert "Hello, Ada Lovelace!" in html
    assert re.search(r'<form action="/logout" method="POST"[^>]*>\s*<input type="hidden" name="csrf_token"', html)
    assert 'href="/logout"' not in html


def test_registration_never_chooses_role_or_active_state(fake, fake_client):
    response = post(fake_client, "/register", data={
        "full_name": "Eve", "email": "Eve@Example.edu", "password": "a-long-password",
        "confirm_password": "a-long-password", "role": "admin", "is_active": "0"})
    assert response.status_code == 302 and response.headers["Location"].endswith("/login")
    (user,) = fake.users.values()
    assert user["role"] == "student" and user["is_active"] == 1 and user["email"] == "eve@example.edu"
    assert user["password_hash"].startswith(("scrypt:", "pbkdf2:")) and "a-long-password" not in user["password_hash"]
    inserts = [s for s in fake.all_statements() if s.startswith("INSERT INTO users")]
    assert inserts == ["INSERT INTO users (full_name, email, password_hash) VALUES (%s, %s, %s)"]
    assert fake.writes[-1][1] is None                         # anonymous request: @app_user_id NULL


def test_registration_by_a_signed_in_visitor_is_not_attributed_to_them(fake, fake_client):
    # /register is public and does not require the visitor to be anonymous.  The
    # connection of a signed-in visitor starts with their identity, so the route
    # has to clear @app_user_id itself before it inserts the new user.
    insert = "INSERT INTO users (full_name, email, password_hash) VALUES (%s, %s, %s)"
    visitor = fake.add_user("ada@example.edu")
    login_as(fake_client, visitor)
    response = post(fake_client, "/register", data={
        "full_name": "Eve", "email": "eve@example.edu", "password": "a-long-password",
        "confirm_password": "a-long-password"})
    assert response.status_code == 302 and response.headers["Location"].endswith("/login")
    assert sorted(u["email"] for u in fake.users.values()) == ["ada@example.edu", "eve@example.edu"]
    (created,) = [u for u in fake.users.values() if u["email"] == "eve@example.edu"]
    assert created["user_id"] != visitor and created["full_name"] == "Eve"
    # Not an anonymous request: the connection was opened as the signed-in visitor ...
    (conn,) = fake.connections
    assert conn.statements[0] == (SET_IDENTITY, (visitor,))
    # ... the identity was cleared directly before the INSERT, and never set again ...
    statements = [stmt for stmt, _ in conn.statements]
    inserted = statements.index(insert)
    assert conn.statements[inserted - 1] == (SET_IDENTITY, (None,))
    assert [args[0] for stmt, args in conn.statements if stmt == SET_IDENTITY] == [visitor, None]
    # ... so the only write of the request ran with @app_user_id NULL, and was committed.
    assert fake.writes == [(conn.id, None, insert)]
    assert conn.events.index(("commit",)) > conn.events.index(("execute", insert))


def test_registration_with_a_taken_email_is_a_form_error(fake, fake_client):
    fake.add_user("ada@example.edu")
    response = post(fake_client, "/register", data={"full_name": "Ada", "email": "ada@example.edu",
                                                    "password": "a-long-password",
                                                    "confirm_password": "a-long-password"})
    assert response.status_code == 400 and b"already registered" in response.data


def test_account_settings_change_name_and_password_only(fake, fake_client):
    uid = fake.add_user("ada@example.edu", name="Ada")
    login_as(fake_client, uid)
    page = fake_client.get("/accountSettings")
    assert page.status_code == 200 and b"ada@example.edu" in page.data
    assert b"Name updated." in post(fake_client, "/accountSettings",
                                    data={"action": "name", "full_name": "Ada L."}).data
    assert fake.users[uid]["full_name"] == "Ada L."
    wrong = post(fake_client, "/accountSettings", data={"action": "password", "current_password": "nope",
                                                        "new_password": "new-password-1",
                                                        "confirm_password": "new-password-1"})
    assert b"Current password is incorrect." in wrong.data
    ok = post(fake_client, "/accountSettings", data={"action": "password", "current_password": PASSWORD,
                                                     "new_password": "new-password-1",
                                                     "confirm_password": "new-password-1"})
    assert b"Password updated." in ok.data
    updates = [s for s in fake.all_statements() if s.startswith("UPDATE users")]
    assert updates == ["UPDATE users SET full_name = %s WHERE user_id = %s",
                       "UPDATE users SET password_hash = %s WHERE user_id = %s"]
    assert all(user == uid for _, user, stmt in fake.writes if stmt.startswith("UPDATE users"))


# ================================================================ request-scoped database (fake database)

def test_one_connection_per_request_opened_as_campus_app(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    fake.add_room("Study Room")
    login_as(fake_client, uid)
    start = tomorrow_at(10)
    post(fake_client, "/rooms/Study%20Room/confirmBooking", data={"date": start.date().isoformat(),
                                                                "time": slot(start), "people": "2"})
    assert len(fake.connections) == 1                         # login check, housekeeping-free confirm, insert
    (kwargs,) = fake.connect_calls
    assert kwargs["user"] == "campus_app" and kwargs["password"] == "fake-app-password-123"
    assert kwargs["autocommit"] is False and kwargs["database"] == "university_resources"
    conn = fake.connections[0]
    assert conn.closed and conn.events[-2:] == [("rollback",), ("close",)]


def test_no_database_needed_for_public_pages(fake, fake_client):
    for path in ("/", "/lab", "/login", "/register"):
        assert fake_client.get(path).status_code == 200
    assert fake.connections == []


def test_app_user_id_is_set_first_for_the_signed_in_user(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid)
    fake_client.get("/accountProfile")
    conn = fake.connections[0]
    assert conn.statements[0] == ("SET @app_user_id = %s", (uid,))


def test_anonymous_requests_set_app_user_id_to_null(fake, fake_client):
    fake_client.get("/healthz")
    post(fake_client, "/login", data={"email": "x@example.edu", "password": "y"})
    assert [c.statements[0] for c in fake.connections] == [("SET @app_user_id = %s", (None,))] * 2


def test_writes_are_attributed_to_the_acting_user(fake, fake_app):
    alice, bob = fake.add_user("alice@example.edu"), fake.add_user("bob@example.edu")
    fake.add_item("Chess", "Chess A")
    fake.add_item("Chess", "Chess B")
    start = tomorrow_at(11)
    for uid, version in ((alice, "Chess A"), (bob, "Chess B")):
        c = fake_app.test_client()
        login_as(c, uid)
        post(c, "/items/Chess/confirmBooking", data={"version": version, "date": start.date().isoformat(),
                                                     "time": slot(start)})
    inserts = [(user, stmt) for _, user, stmt in fake.writes if stmt.startswith("INSERT INTO loans")]
    assert [u for u, _ in inserts] == [alice, bob]


def test_failed_insert_is_rolled_back_and_hidden_from_the_user(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    fake.add_room("Study Room")
    login_as(fake_client, uid)
    fake.fail_statement = (r"^INSERT INTO bookings",
                           pymysql.err.OperationalError(1452, "Cannot add row: SELECT secret_sql FROM x"))
    start = tomorrow_at(12)
    response = post(fake_client, "/rooms/Study%20Room/confirmBooking",
                    data={"date": start.date().isoformat(), "time": slot(start), "people": "1"})
    assert response.status_code == 500
    assert b"secret_sql" not in response.data and b"Traceback" not in response.data
    assert fake.bookings == []
    events = fake.connections[0].events
    assert ("commit",) not in events[events.index(("begin",)):]
    assert ("rollback",) in events[events.index(("begin",)):]


def test_connection_failure_is_a_503_page_without_secrets(fake, fake_client):
    fake.fail_connect = pymysql.err.OperationalError(
        1045, "Access denied for user 'campus_app'@'10.0.0.5' (using password: YES)")
    login_as(fake_client, 1)
    response = fake_client.get("/accountProfile")
    assert response.status_code == 503
    assert b"cannot reach its database" in response.data
    assert b"fake-app-password-123" not in response.data and b"10.0.0.5" not in response.data
    health = fake_client.get("/healthz")
    assert health.status_code == 503 and health.get_json() == {"status": "error", "database": "login failed",
                                                               "code": 1045}


def test_missing_database_password_never_falls_back(fake):
    app = webapp.create_app({"TESTING": True, "SECRET_KEY": "x", "DB_PASSWORD": None})
    response = app.test_client().get("/healthz")
    assert response.status_code == 503
    assert fake.connect_calls == []                           # no attempt with another account or no password


@pytest.mark.parametrize("password", [None, ""])
def test_missing_database_password_is_the_safe_unavailable_page(monkeypatch, fake, password):
    # Other credentials within reach of the process must not be tried instead.
    monkeypatch.setenv("DB_ADMIN_USER", "root")
    monkeypatch.setenv("MYSQL_PWD", "operator-secret-1")
    monkeypatch.setenv("MARIADB_ROOT_PASSWORD", "root-secret-2")
    app = webapp.create_app({"TESTING": True, "SECRET_KEY": "x", "DB_USER": "campus_app",
                             "DB_PASSWORD": password})
    c = app.test_client()
    login_as(c, 1)
    page = c.get("/accountProfile")
    assert page.status_code == 503 and b"cannot reach its database" in page.data
    assert b"operator-secret-1" not in page.data and b"root-secret-2" not in page.data
    health = c.get("/healthz")
    assert health.status_code == 503 and health.get_json()["status"] == "error"
    assert fake.connect_calls == []


# ================================================================ housekeeping attribution (fake database)
#
# The fake records @app_user_id with every write statement.  What the real
# triggers store for these writes (application_user_id NULL, and event_source
# 'direct_sql', because database/triggers.sql derives it from @app_user_id
# being NULL) can only be checked against MariaDB.

SET_IDENTITY = "SET @app_user_id = %s"
HOUSEKEEPING_LOANS = ("UPDATE loans SET status = 'returned', returned_at = CURRENT_TIMESTAMP(6) "
                      "WHERE status = 'active'")
HOUSEKEEPING_BOOKINGS = "UPDATE bookings SET status = 'completed' WHERE status = 'confirmed'"
HOUSEKEEPING = (HOUSEKEEPING_LOANS, HOUSEKEEPING_BOOKINGS)


def add_overdue_reservations(fake, owner):
    """A past confirmed booking and an overdue active loan of `owner`."""
    room, item = fake.add_room("Study Room"), fake.add_item("Chess", "Chess A")
    past = datetime.now() - timedelta(days=2)
    fake.add_booking(owner, room, past, past + timedelta(hours=1))
    fake.add_loan(owner, item, past, past + timedelta(hours=1))
    return room


def restore_fails(conn, statement, args):
    """fail_statement matcher: the SET that follows the housekeeping's SET ... NULL."""
    return statement == SET_IDENTITY and conn.app_user_id is None


def fail_housekeeping(fake, failure):
    """Makes one step of the housekeeping fail: 'loans_update', 'bookings_update' or 'commit'."""
    error = pymysql.err.OperationalError(1205, "Lock wait timeout exceeded")
    if failure == "commit":
        fake.fail_commit = error
    else:
        failing = HOUSEKEEPING_LOANS if failure == "loans_update" else HOUSEKEEPING_BOOKINGS
        fake.fail_statement = ("^" + re.escape(failing), error)
    return error


@pytest.mark.parametrize("path", ["/accountBookings", "/items/Chess", "/rooms/Study%20Room"])
def test_housekeeping_is_not_attributed_to_the_visiting_student(fake, fake_client, path):
    visitor, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    add_overdue_reservations(fake, other)
    login_as(fake_client, visitor)
    assert fake_client.get(path).status_code == 200
    (conn,) = fake.connections
    assert fake.bookings[0]["status"] == "completed" and fake.loans[0]["status"] == "returned"
    # Both housekeeping writes ran with @app_user_id NULL, not as the visitor.
    assert [(c, user, stmt.startswith(HOUSEKEEPING)) for c, user, stmt in fake.writes] == [
        (conn.id, None, True), (conn.id, None, True)]
    # NULL exactly around the two UPDATEs and their commit, then the visitor again.
    assert [args[0] for stmt, args in conn.statements if stmt == SET_IDENTITY] == [visitor, None, visitor]
    statements = [stmt for stmt, _ in conn.statements]
    cleared = statements.index(SET_IDENTITY, 1)
    assert statements[cleared + 1].startswith(HOUSEKEEPING_LOANS)
    assert statements[cleared + 2].startswith(HOUSEKEEPING_BOOKINGS)
    assert statements[cleared + 3] == SET_IDENTITY
    committed = conn.events.index(("commit",))
    assert conn.events[committed - 1][1].startswith(HOUSEKEEPING_BOOKINGS)
    assert conn.events[committed + 1] == ("execute", SET_IDENTITY)
    assert conn.app_user_id == visitor


def test_write_after_housekeeping_is_attributed_to_the_student_again(fake, fake_app):
    visitor, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    room = add_overdue_reservations(fake, other)
    start = tomorrow_at(10)
    own = fake.add_booking(visitor, room, start, start + timedelta(hours=1))
    with fake_app.test_request_context("/accountBookings"):
        flask.session["user_id"] = visitor
        db = webapp.get_db()
        webapp.expire_finished_reservations(db)
        assert db.app_user_id == visitor
        assert webapp.cancel_reservation(db, visitor, "room", own) == "Booking cancelled."
    assert len(fake.connections) == 1                         # the same connection throughout
    assert [(c, user) for c, user, _ in fake.writes] == [(db.id, None), (db.id, None), (db.id, visitor)]
    assert fake.writes[-1][2].startswith("UPDATE bookings SET status = 'cancelled'")
    assert db.closed


@pytest.mark.parametrize("failure", ["loans_update", "bookings_update", "commit"])
def test_failed_housekeeping_is_rolled_back_and_the_identity_restored(fake, fake_app, failure):
    visitor, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    room = add_overdue_reservations(fake, other)
    start = tomorrow_at(10)
    own = fake.add_booking(visitor, room, start, start + timedelta(hours=1))
    fail_housekeeping(fake, failure)
    with fake_app.test_request_context("/accountBookings"):
        flask.session["user_id"] = visitor
        db = webapp.get_db()
        webapp.expire_finished_reservations(db)               # logged, not raised: the page still loads
        assert db.app_user_id == visitor and not db.closed
        assert flask.g.db is db and len(fake.connections) == 1
        # Nothing of the failed cleanup stays behind.
        assert fake.bookings[0]["status"] == "confirmed" and fake.loans[0]["status"] == "active"
        assert ("rollback",) in db.events[db.events.index(("execute", SET_IDENTITY), 1):]
        # The connection is reused, with the right identity.
        assert webapp.cancel_reservation(db, visitor, "room", own) == "Booking cancelled."
    assert fake.writes[-1][:2] == (db.id, visitor)
    assert fake.writes[-1][2].startswith("UPDATE bookings SET status = 'cancelled'")
    assert all(user is None for _, user, stmt in fake.writes if stmt.startswith(HOUSEKEEPING))
    assert all(user == visitor for _, user, stmt in fake.writes if not stmt.startswith(HOUSEKEEPING))


def test_connection_is_discarded_when_the_identity_cannot_be_restored(fake, fake_client):
    visitor, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    add_overdue_reservations(fake, other)
    login_as(fake_client, visitor)
    fake.fail_statement = (restore_fails, pymysql.err.OperationalError(2013, "Lost connection during query"))
    response = fake_client.get("/accountBookings")
    assert response.status_code == 500
    assert b"Lost connection" not in response.data and b"Traceback" not in response.data
    (conn,) = fake.connections                                # no second connection, no retry
    assert conn.closed and conn.app_user_id is None           # the identity was never restored ...
    assert conn.statements[-1] == (SET_IDENTITY, (visitor,))  # ... and nothing ran on it afterwards
    assert all(user is None for _, user, _ in fake.writes)


def test_after_a_failed_restore_the_request_gets_a_fresh_connection(fake, fake_app):
    visitor, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    room = add_overdue_reservations(fake, other)
    start = tomorrow_at(10)
    own = fake.add_booking(visitor, room, start, start + timedelta(hours=1))
    with fake_app.test_request_context("/accountBookings"):
        flask.session["user_id"] = visitor
        db = webapp.get_db()
        fake.fail_statement = (restore_fails, pymysql.err.OperationalError(2013, "Lost connection during query"))
        with pytest.raises(pymysql.err.OperationalError):
            webapp.expire_finished_reservations(db)
        assert db.closed
        fresh = webapp.get_db()
        assert fresh is not db and fresh.app_user_id == visitor
        assert webapp.cancel_reservation(fresh, visitor, "room", own) == "Booking cancelled."
    assert fake.writes[-1][:2] == (fresh.id, visitor)
    assert not [w for w in fake.writes if w[0] == db.id and w[1] is not None]


def test_fake_failed_rollback_leaves_the_transaction_pending_until_close(fake):
    other = fake.add_user("bob@example.edu")
    add_overdue_reservations(fake, other)
    conn = fake.connect()
    conn.cursor().execute(HOUSEKEEPING_BOOKINGS)
    error = pymysql.err.OperationalError(2013, "Lost connection during query")
    fake.fail_rollback = error
    with pytest.raises(pymysql.err.OperationalError) as raised:
        conn.rollback()
    assert raised.value is error and fake.fail_rollback is None
    assert conn.events[-1] == ("rollback",)                   # the attempt is recorded ...
    assert fake.bookings[0]["status"] == "completed"          # ... but nothing was undone
    conn.close()                                              # the server rolls back on disconnect
    assert fake.bookings[0]["status"] == "confirmed"
    # Without a configured failure, rollback undoes the writes as before.
    conn = fake.connect()
    conn.cursor().execute(HOUSEKEEPING_BOOKINGS)
    conn.rollback()
    assert fake.bookings[0]["status"] == "confirmed" and not conn.closed


@pytest.mark.parametrize("failure", ["loans_update", "bookings_update", "commit"])
def test_connection_is_discarded_when_the_housekeeping_rollback_fails(fake, fake_app, failure):
    visitor, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    room = add_overdue_reservations(fake, other)
    start = tomorrow_at(10)
    own = fake.add_booking(visitor, room, start, start + timedelta(hours=1))
    fail_housekeeping(fake, failure)
    rollback_error = pymysql.err.OperationalError(2013, "Lost connection during query")
    fake.fail_rollback = rollback_error
    with fake_app.test_request_context("/accountBookings"):
        flask.session["user_id"] = visitor
        db = webapp.get_db()
        with pytest.raises(pymysql.err.OperationalError) as raised:
            webapp.expire_finished_reservations(db)
        assert raised.value is rollback_error                 # the rollback error, not swallowed or replaced
        # Rollback was attempted, then the connection was closed at once and detached from the request.
        assert db.events[-2:] == [("rollback",), ("close",)]
        assert db.closed and "db" not in flask.g
        # No identity restoration on the discarded connection: the housekeeping's NULL was its last SET.
        assert [args[0] for stmt, args in db.statements if stmt == SET_IDENTITY] == [visitor, None]
        assert db.app_user_id is None
        # Closing ended the uncertain transaction: nothing of the cleanup stays behind.
        assert fake.bookings[0]["status"] == "confirmed" and fake.loans[0]["status"] == "active"
        assert not fake.held_locks()
        # The request continues on a new connection, identified from the session.
        fresh = webapp.get_db()
        assert fresh is not db and fresh.id != db.id and not fresh.closed
        assert fresh.statements[0] == (SET_IDENTITY, (visitor,)) and fresh.app_user_id == visitor
        assert webapp.cancel_reservation(fresh, visitor, "room", own) == "Booking cancelled."
        statements_on_discarded = len(db.statements)
    assert len(fake.connections) == 2
    assert fake.writes[-1][:2] == (fresh.id, visitor)
    assert fake.writes[-1][2].startswith("UPDATE bookings SET status = 'cancelled'")
    # The discarded connection wrote nothing but (NULL-attributed) housekeeping, and nothing after its close.
    assert all(user is None and stmt.startswith(HOUSEKEEPING) for c, user, stmt in fake.writes if c == db.id)
    assert len(db.statements) == statements_on_discarded and db.events[-1] == ("close",)


def test_failed_housekeeping_rollback_is_a_generic_500_on_a_discarded_connection(fake, fake_client):
    visitor, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    add_overdue_reservations(fake, other)
    login_as(fake_client, visitor)
    fail_housekeeping(fake, "bookings_update")
    fake.fail_rollback = pymysql.err.OperationalError(2013, "Lost connection during query")
    response = fake_client.get("/accountBookings")
    assert response.status_code == 500
    assert b"Lost connection" not in response.data and b"Traceback" not in response.data
    (conn,) = fake.connections                                # no second connection, no retry
    assert conn.closed and conn.app_user_id is None
    assert conn.events[-2:] == [("rollback",), ("close",)]    # the failed rollback, then nothing but the close
    assert [args[0] for stmt, args in conn.statements if stmt == SET_IDENTITY] == [visitor, None]
    assert all(user is None for _, user, _ in fake.writes)
    assert fake.bookings[0]["status"] == "confirmed" and fake.loans[0]["status"] == "active"


def test_housekeeping_of_an_anonymous_connection_stays_null(fake, fake_app):
    other = fake.add_user("bob@example.edu")
    add_overdue_reservations(fake, other)
    with fake_app.test_request_context("/"):
        db = webapp.get_db()
        webapp.expire_finished_reservations(db)
        assert db.app_user_id is None
    assert [user for _, user, _ in fake.writes] == [None, None]


def test_healthz_ok_is_read_only(fake, fake_client):
    response = fake_client.get("/healthz")
    assert response.status_code == 200 and response.get_json() == {"status": "ok", "database": "ok"}
    assert fake.writes == []


def test_unknown_database_error_is_a_generic_500(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid)
    fake.fail_statement = (r"^SELECT full_name FROM users",
                           pymysql.err.ProgrammingError(1054, "Unknown column 'password_hash_leak' in SELECT"))
    response = fake_client.get("/accountProfile")
    assert response.status_code == 500
    assert b"password_hash_leak" not in response.data and b"SELECT" not in response.data


# ================================================================ bookings (fake database)

def test_room_booking_is_saved_with_the_chosen_slot(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    room = fake.add_room("Study Room")
    login_as(fake_client, uid)
    start = tomorrow_at(20)
    response = post(fake_client, "/rooms/Study%20Room/confirmBooking",
                    data={"date": start.date().isoformat(), "time": slot(start), "people": "3"})
    assert response.status_code == 302 and response.headers["Location"].endswith("/roomsHome")
    (booking,) = fake.bookings
    assert (booking["user_id"], booking["room_id"], booking["status"]) == (uid, room, "confirmed")
    assert (booking["start_time"], booking["end_time"]) == (start, start + timedelta(hours=1))


def test_item_booking_keeps_the_scheduled_future_borrowing_time(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    fake.add_item("Chess", "Chess A")
    chess_b = fake.add_item("Chess", "Chess B")
    login_as(fake_client, uid)
    start = datetime.combine(date.today() + timedelta(days=10), datetime.min.time()).replace(hour=15)
    response = post(fake_client, "/items/Chess/confirmBooking",
                    data={"version": "Chess B", "date": start.date().isoformat(), "time": slot(start)})
    assert response.status_code == 302 and response.headers["Location"].endswith("/itemsHome")
    (loan,) = fake.loans
    assert loan["item_id"] == chess_b and loan["status"] == "active"
    assert (loan["borrowed_at"], loan["due_at"]) == (start, start + timedelta(hours=1))   # not NOW()
    inserts = [s for s in fake.all_statements() if s.startswith("INSERT INTO loans")]
    assert inserts and all("NOW(" not in s for s in inserts)


def test_booking_runs_check_and_insert_in_one_locking_transaction(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    fake.add_room("Study Room")
    login_as(fake_client, uid)
    start = tomorrow_at(9)
    post(fake_client, "/rooms/Study%20Room/confirmBooking",
         data={"date": start.date().isoformat(), "time": slot(start), "people": "1"})
    events = fake.connections[0].events
    tx = events[events.index(("begin",)):]
    kinds = [e[0] if e[0] != "execute" else e[1].split(" FROM ")[0][:20] + (" LOCK" if "FOR UPDATE" in e[1] else "")
             for e in tx]
    assert kinds[:5] == ["begin", "SELECT room_id, stat LOCK", "SELECT COUNT(*) LOCK", "INSERT INTO bookings", "commit"]


@pytest.mark.parametrize("kind,path,form", [
    ("room", "/rooms/Study%20Room/confirmBooking", {"people": "1"}),
    ("item", "/items/Chess/confirmBooking", {"version": "Chess A"}),
])
def test_overlapping_reservation_is_rejected_and_rolled_back(fake, fake_client, kind, path, form):
    uid, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    start = tomorrow_at(14)
    if kind == "room":
        room = fake.add_room("Study Room")
        fake.add_booking(other, room, start, start + timedelta(hours=1))
    else:
        item = fake.add_item("Chess", "Chess A")
        fake.add_loan(other, item, start - timedelta(minutes=30), start + timedelta(minutes=30))
    login_as(fake_client, uid)
    response = post(fake_client, path, data=dict(form, date=start.date().isoformat(), time=slot(start)))
    assert response.status_code == 200 and b"That time slot is already booked." in response.data
    assert len(fake.bookings if kind == "room" else fake.loans) == 1
    events = fake.connections[0].events
    tx = events[events.index(("begin",)):]
    assert ("commit",) not in tx and ("rollback",) in tx


def test_other_item_version_in_the_same_slot_is_free(fake, fake_client):
    uid, other = fake.add_user("ada@example.edu"), fake.add_user("bob@example.edu")
    a = fake.add_item("Chess", "Chess A")
    fake.add_item("Chess", "Chess B")
    start = tomorrow_at(16)
    fake.add_loan(other, a, start, start + timedelta(hours=1))
    login_as(fake_client, uid)
    post(fake_client, "/items/Chess/confirmBooking",
         data={"version": "Chess B", "date": start.date().isoformat(), "time": slot(start)})
    assert len(fake.loans) == 2


def test_cancelled_and_returned_loans_do_not_block_a_slot(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    item = fake.add_item("Chess", "Chess A")
    start = tomorrow_at(17)
    fake.add_loan(uid, item, start, start + timedelta(hours=1), status="cancelled")
    login_as(fake_client, uid)
    post(fake_client, "/items/Chess/confirmBooking",
         data={"version": "Chess A", "date": start.date().isoformat(), "time": slot(start)})
    assert [l["status"] for l in fake.loans] == ["cancelled", "active"]


def test_rooms_under_maintenance_and_unknown_resources_are_rejected(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    fake.add_room("Cinema Room", status="maintenance")
    login_as(fake_client, uid)
    start = tomorrow_at(18)
    data = {"date": start.date().isoformat(), "time": slot(start), "people": "1"}
    assert b"not available" in post(fake_client, "/rooms/Cinema%20Room/confirmBooking", data=data).data
    assert b"does not exist" in post(fake_client, "/rooms/No%20Such%20Room/confirmBooking", data=data).data
    assert fake.bookings == []


def test_quiet_hours_are_enforced_on_confirm(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    fake.add_room("Study Room")
    login_as(fake_client, uid)
    response = post(fake_client, "/rooms/Study%20Room/confirmBooking",
                    data={"date": (date.today() + timedelta(days=1)).isoformat(), "time": "22:00 - 23:00",
                          "people": "1"})
    assert b"valid date and time slot" in response.data and fake.bookings == []


def test_verify_page_shows_the_choice_without_saving(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    fake.add_item("Chess", "Chess A")
    login_as(fake_client, uid)
    start = tomorrow_at(13)
    response = post(fake_client, "/items/Chess/verifyBooking",
                    data={"version": "Chess A", "date": start.date().isoformat(), "time": slot(start)})
    assert response.status_code == 200 and b"Confirm Booking: Chess" in response.data
    assert b'name="csrf_token"' in response.data and fake.loans == []


@pytest.mark.parametrize("kind", ["room", "item"])
def test_concurrent_bookings_of_one_slot_create_one_reservation(fake, kind):
    """Six transactions race for the same slot; the row lock lets exactly one through."""
    users = [fake.add_user(f"u{i}@example.edu") for i in range(6)]
    if kind == "room":
        fake.add_room("Study Room")
    else:
        fake.add_item("Chess", "Chess A")
    start = tomorrow_at(10)
    end = start + timedelta(hours=1)
    fake.slow_after_lock = lambda: time.sleep(0.01)           # widen the window between check and insert
    barrier = threading.Barrier(len(users))
    results = []

    def attempt(uid):
        conn = fake.connect(user="campus_app")
        barrier.wait()
        try:
            if kind == "room":
                webapp.book_room(conn, uid, "Study Room", start, end)
            else:
                webapp.book_item(conn, uid, "Chess", "Chess A", start, end)
            results.append("ok")
        except webapp.BookingError:
            results.append("rejected")
        finally:
            conn.close()

    threads = [threading.Thread(target=attempt, args=(uid,)) for uid in users]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == ["ok"] + ["rejected"] * 5
    assert len(fake.bookings if kind == "room" else fake.loans) == 1


def test_lock_wait_timeout_becomes_a_retry_message(fake):
    fake.add_room("Study Room")
    conn = fake.connect(user="campus_app")
    fake.fail_statement = (r"FROM rooms .* FOR UPDATE", pymysql.err.OperationalError(1205, "Lock wait timeout"))
    start = tomorrow_at(10)
    with pytest.raises(webapp.BookingError, match="try again"):
        webapp.book_room(conn, 1, "Study Room", start, start + timedelta(hours=1))
    assert conn.events[-1] == ("rollback",)


# ================================================================ cancellation (fake database)

def test_future_item_booking_is_cancelled_not_deleted(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    item = fake.add_item("Chess", "Chess A")
    start = tomorrow_at(10)
    loan = fake.add_loan(uid, item, start, start + timedelta(hours=1))
    login_as(fake_client, uid)
    response = post(fake_client, "/cancelBooking", data={"booking_id": str(loan), "kind": "item"})
    assert response.status_code == 302 and response.headers["Location"].endswith("/accountBookings")
    (row,) = fake.loans
    assert row["status"] == "cancelled" and row["returned_at"] is None
    assert (row["borrowed_at"], row["due_at"]) == (start, start + timedelta(hours=1))
    assert not [s for s in fake.all_statements() if s.startswith("DELETE")]
    assert [u for _, u, s in fake.writes if "SET status = 'cancelled'" in s] == [uid]


def test_started_item_loan_is_returned(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    item = fake.add_item("Chess", "Chess A")
    now = datetime.now()
    loan = fake.add_loan(uid, item, now - timedelta(minutes=30), now + timedelta(minutes=30))
    login_as(fake_client, uid)
    post(fake_client, "/cancelBooking", data={"booking_id": str(loan), "kind": "item"})
    (row,) = fake.loans
    assert row["status"] == "returned" and row["returned_at"] is not None
    assert row["returned_at"] >= row["borrowed_at"]


def test_room_booking_cancellation(fake, fake_client):
    uid = fake.add_user("ada@example.edu")
    room = fake.add_room("Study Room")
    start = tomorrow_at(10)
    booking = fake.add_booking(uid, room, start, start + timedelta(hours=1))
    login_as(fake_client, uid)
    post(fake_client, "/cancelBooking", data={"booking_id": str(booking), "kind": "room"})
    assert fake.bookings[0]["status"] == "cancelled"
    follow = post(fake_client, "/cancelBooking", data={"booking_id": str(booking), "kind": "room"},
                  follow_redirects=True)
    assert b"cannot be cancelled" in follow.data             # only confirmed bookings


@pytest.mark.parametrize("kind", ["room", "item"])
def test_users_cannot_cancel_other_users_bookings(fake, fake_client, kind):
    owner, intruder = fake.add_user("owner@example.edu"), fake.add_user("intruder@example.edu")
    start = tomorrow_at(10)
    if kind == "room":
        target = fake.add_booking(owner, fake.add_room("Study Room"), start, start + timedelta(hours=1))
    else:
        target = fake.add_loan(owner, fake.add_item("Chess", "Chess A"), start, start + timedelta(hours=1))
    login_as(fake_client, intruder)
    response = post(fake_client, "/cancelBooking", data={"booking_id": str(target), "kind": kind},
                    follow_redirects=True)
    assert b"cannot be cancelled" in response.data
    rows = fake.bookings if kind == "room" else fake.loans
    assert rows[0]["status"] == ("confirmed" if kind == "room" else "active")


@pytest.mark.parametrize("form", [{"booking_id": "1 OR 1=1", "kind": "item"}, {"booking_id": "5", "kind": "user"},
                                  {"kind": "room"}])
def test_malformed_cancellation_changes_nothing(fake, fake_client, form):
    uid = fake.add_user("ada@example.edu")
    login_as(fake_client, uid)
    post(fake_client, "/cancelBooking", data=form)
    assert not [s for s in fake.all_statements() if "cancelled" in s or "returned" in s and "loan_id" in s]


# ================================================================ templates (fake database)

def test_account_and_booking_pages_render(fake, fake_client):
    uid = fake.add_user("ada@example.edu", name="Ada")
    room = fake.add_room("Study Room")
    item = fake.add_item("Chess", "Chess A")
    start = tomorrow_at(10)
    fake.add_booking(uid, room, start, start + timedelta(hours=1))
    fake.add_loan(uid, item, start, start + timedelta(hours=1))
    login_as(fake_client, uid)
    for path, text in [("/accountProfile", "Hello, Ada!"), ("/accountBookings", "Room: Study Room"),
                       ("/accountBookings", "Version: Chess A"), ("/accountSettings", "Change Password"),
                       ("/itemsHome", "Settlers of Catan"), ("/roomsHome", "Cinema Room"),
                       ("/items/Chess", "Book: Chess"), ("/rooms/Study%20Room", "Book: Study Room")]:
        response = fake_client.get(path)
        assert response.status_code == 200, path
        assert text in response.data.decode(), (path, text)
    bookings = fake_client.get("/accountBookings").data.decode()
    assert bookings.count('name="csrf_token"') == 2 and 'action="/cancelBooking"' in bookings


def test_navigation_keeps_official_links_and_adds_lab_and_admin(fake, fake_client):
    student = fake.add_user("ada@example.edu")
    login_as(fake_client, student)
    nav = fake_client.get("/").data.decode()
    for href in ('href="/itemsHome"', 'href="/roomsHome"', 'href="/accountProfile"', 'href="/lab"'):
        assert href in nav
    assert 'href="/admin/audit"' not in nav
    login_as(fake_client, student, "admin")
    assert 'href="/admin/audit"' in fake_client.get("/").data.decode()


# ================================================================ admin page (fake database)

def test_admin_audit_requires_the_admin_role_in_the_database(fake, fake_client):
    uid = fake.add_user("ada@example.edu", role="student")
    login_as(fake_client, uid, "admin")                        # a stale or forged session role
    assert fake_client.get("/admin/audit").status_code == 403
    with fake_client.session_transaction() as s:
        assert s["role"] == "student"


def test_admin_audit_rejects_anonymous_users(fake_client):
    response = fake_client.get("/admin/audit")
    assert response.status_code == 302 and "/login" in response.headers["Location"]


def test_admin_audit_renders_read_only_history(fake, fake_client):
    admin = fake.add_user("root.admin@example.edu", role="admin")
    fake.audit_events = [{
        "event_id": 7, "event_time": datetime(2026, 11, 12, 10), "action": "UPDATE", "entity_table": "loans",
        "entity_id": "3", "database_user": "campus_app@%", "application_user_id": admin,
        "event_source": "application", "connection_id": 42,
        "old_values": json.dumps({"status": "active"}),
        "new_values": json.dumps({"status": "cancelled", "note": "<script>alert(1)</script>"}),
    }, {
        "event_id": 6, "event_time": datetime(2026, 11, 12, 9), "action": "INSERT", "entity_table": "users",
        "entity_id": "9", "database_user": None, "application_user_id": None, "event_source": "direct_sql",
        "connection_id": None, "old_values": None, "new_values": "not json {",
    }]
    login_as(fake_client, admin, "admin")
    response = fake_client.get("/admin/audit")
    html = response.data.decode()
    assert response.status_code == 200 and "Row changes (SQL triggers)" in html
    assert "&#34;cancelled&#34;" in html or "&quot;cancelled&quot;" in html
    assert "<script>alert(1)</script>" not in html and "&lt;script&gt;" in html
    assert "not json {" in html
    assert "<form" not in html.split("<!-- Intro Card -->")[1]   # nothing on the page writes
    assert fake.writes == []


def test_admin_audit_is_paginated_and_bounded(fake, fake_client):
    admin = fake.add_user("root.admin@example.edu", role="admin")
    login_as(fake_client, admin, "admin")
    fake_client.get("/admin/audit?page=3")
    fake_client.get("/admin/audit?page=999999")
    fake_client.get("/admin/audit?page=-5")
    args = [a for c in fake.connections for s, a in c.statements if "FROM audit_events ORDER BY" in s]
    assert args == [(51, 100), (51, (webapp.AUDIT_MAX_PAGE - 1) * 50), (51, 0)]


def test_admin_audit_survives_missing_plugin_and_history(fake, fake_client):
    admin = fake.add_user("root.admin@example.edu", role="admin")
    fake.plugin_installed = False
    fake.audit_error = pymysql.err.OperationalError(1142, "SELECT command denied ... audit_events")
    login_as(fake_client, admin, "admin")
    response = fake_client.get("/admin/audit")
    html = response.data.decode()
    assert response.status_code == 200
    assert "not installed or not active" in html and "not readable" in html
    assert "command denied" not in html


# ================================================================ grant contract (static and dynamic)

APP_SOURCE = (FRONTEND / "app.py").read_text(encoding="utf-8") + (FRONTEND / "lab.py").read_text(encoding="utf-8")


def test_source_stays_inside_the_campus_app_grants():
    sql = " ".join(APP_SOURCE.split())
    deletes = re.findall(r"DELETE FROM (\w+)", sql)
    assert set(deletes) <= {"audit_lab_notes", "bookings"}     # bookings: the lab's deliberately denied statement
    assert "DELETE FROM bookings WHERE booking_id = 0" in sql and "DELETE FROM loans" not in sql
    assert re.findall(r"INSERT INTO users \(([^)]*)\)", sql) == ["full_name, email, password_hash"]
    assert set(re.findall(r"UPDATE users SET (\w+)", sql)) == {"full_name", "password_hash"}
    assert not re.search(r"(INSERT INTO|UPDATE|DELETE FROM) (audit_events|campus_audit\.)", sql)
    assert not re.search(r"(INSERT INTO|UPDATE) (rooms|items)\b", sql)
    assert "user=\"root\"" not in APP_SOURCE and "user='root'" not in APP_SOURCE


def test_every_flow_respects_the_grants_at_run_time(fake, fake_client):
    """fakedb raises 1142/1143 for any statement outside database/app_account.sh."""
    uid = fake.add_user("ada@example.edu")
    room = fake.add_room("Study Room")
    item = fake.add_item("Chess", "Chess A")
    start = tomorrow_at(19)
    login_as(fake_client, uid)
    day, time_slot = start.date().isoformat(), slot(start)
    flows = [
        ("/rooms/Study%20Room/confirmBooking", {"date": day, "time": time_slot, "people": "1"}),
        ("/items/Chess/confirmBooking", {"version": "Chess A", "date": day, "time": time_slot}),
        ("/accountSettings", {"action": "name", "full_name": "Ada"}),
        ("/accountSettings", {"action": "password", "current_password": PASSWORD,
                              "new_password": "another-pass-1", "confirm_password": "another-pass-1"}),
    ]
    for path, data in flows:
        assert post(fake_client, path, data=data).status_code in (200, 302), path
    for b in list(fake.bookings):
        post(fake_client, "/cancelBooking", data={"booking_id": str(b["booking_id"]), "kind": "room"})
    for l in list(fake.loans):
        post(fake_client, "/cancelBooking", data={"booking_id": str(l["loan_id"]), "kind": "item"})
    fake_client.get("/accountBookings")
    fake_client.get("/rooms/Study%20Room")
    fake_client.get("/items/Chess")
    statements = fake.all_statements()
    assert not [s for s in statements if s.startswith("DELETE")]
    assert {b["status"] for b in fake.bookings} == {"cancelled"} and {l["status"] for l in fake.loans} == {"cancelled"}
    assert room and item


# ================================================================ with database

db_only = pytest.mark.skipif(os.getenv("RUN_DB_TESTS") != "1", reason="set RUN_DB_TESTS=1 to run against MariaDB")


@pytest.fixture()
def db_app():
    return webapp.create_app({"TESTING": True, "SECRET_KEY": "test-only-secret-key"})


@pytest.fixture()
def db_client(db_app):
    return db_app.test_client()


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


def free_slot(kind, name, horizon_days):
    """A random free hourly slot inside the booking horizon, so repeated runs do not collide."""
    for _ in range(200):
        day = date.today() + timedelta(days=random.randint(1, horizon_days))
        start = datetime.combine(day, datetime.min.time()).replace(hour=random.randint(9, 21))
        end = start + timedelta(hours=1)
        if kind == "room":
            busy = scalar("SELECT COUNT(*) FROM bookings b JOIN rooms r ON r.room_id = b.room_id "
                          "WHERE r.name = %s AND b.status = 'confirmed' AND b.start_time < %s AND b.end_time > %s",
                          (name, end, start))
        else:
            busy = scalar("SELECT COUNT(*) FROM loans l JOIN items i ON i.item_id = l.item_id "
                          "WHERE i.asset_tag = %s AND l.status = 'active' AND l.borrowed_at < %s AND l.due_at > %s",
                          (name, end, start))
        if not busy:
            return start, end
    pytest.skip("no free slot found")


@db_only
def test_seed_placeholder_hashes_cannot_log_in(db_client):
    for email in ("alice.student@example.edu", "dana.admin@example.edu"):
        response = post(db_client, "/login", data={"email": email, "password": "TEST_HASH_NOT_FOR_LOGIN"})
        assert response.status_code == 401
    assert scalar("SELECT role FROM users WHERE email=%s", ("dana.admin@example.edu",)) == "student"


@pytest.mark.skipif(not os.getenv("TEST_ADMIN_PASSWORD"), reason="no local bootstrap credential file")
@db_only
def test_generated_local_administrator_can_authenticate(db_client):
    response = post(db_client, "/login", data={
        "email": os.environ["TEST_ADMIN_EMAIL"],
        "password": os.environ["TEST_ADMIN_PASSWORD"],
    })
    assert response.status_code == 302
    with db_client.session_transaction() as session:
        assert session["role"] == "admin"
    response = db_client.get("/admin/audit")
    assert response.status_code == 200 and b"Row changes (SQL triggers)" in response.data


@db_only
def test_register_then_login(db_client):
    email = f"test.{random.randint(0, 10**9)}@example.edu"
    form = {"full_name": "Test Student", "email": email, "password": "a-long-password",
            "confirm_password": "a-long-password", "role": "admin"}
    assert post(db_client, "/register", data=form).status_code == 302
    stored = scalar("SELECT password_hash FROM users WHERE email = %s", (email,))
    assert stored.startswith(("scrypt:", "pbkdf2:")) and "a-long-password" not in stored
    assert scalar("SELECT role FROM users WHERE email = %s", (email,)) == "student"
    assert post(db_client, "/register", data=dict(form, full_name="Again")).status_code == 400
    assert post(db_client, "/login", data={"email": email, "password": "a-long-password"}).status_code == 302


@db_only
def test_room_booking_and_overlap_through_the_official_urls(db_client):
    login_as(db_client, user_id("alice.student@example.edu"))
    start, _ = free_slot("room", "Project Room 12", 80)
    form = {"date": start.date().isoformat(), "time": slot(start), "people": "2"}
    assert post(db_client, "/rooms/Project%20Room%2012/confirmBooking", data=form).status_code == 302
    assert scalar("SELECT COUNT(*) FROM bookings b JOIN rooms r ON r.room_id = b.room_id "
                  "WHERE r.name = 'Project Room 12' AND b.start_time = %s AND b.status = 'confirmed'", (start,)) == 1
    second = post(db_client, "/rooms/Project%20Room%2012/confirmBooking", data=form)
    assert b"already booked" in second.data
    assert scalar("SELECT COUNT(*) FROM bookings b JOIN rooms r ON r.room_id = b.room_id "
                  "WHERE r.name = 'Project Room 12' AND b.start_time = %s AND b.status = 'confirmed'", (start,)) == 1


@db_only
def test_concurrent_bookings_of_one_slot_create_one_booking_in_mariadb():
    users = [user_id("alice.student@example.edu"), user_id("bob.student@example.edu")]
    start, end = free_slot("room", "Room 201", 80)
    results = []
    barrier = threading.Barrier(6)

    def attempt(uid):
        db = connect()
        db.autocommit(False)
        with db.cursor() as cursor:
            cursor.execute("SET @app_user_id = %s", (uid,))
        barrier.wait()
        try:
            webapp.book_room(db, uid, "Room 201", start, end)
            results.append("ok")
        except webapp.BookingError:
            results.append("rejected")
        finally:
            db.close()

    threads = [threading.Thread(target=attempt, args=(users[i % 2],)) for i in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == ["ok"] + ["rejected"] * 5
    assert scalar("SELECT COUNT(*) FROM bookings b JOIN rooms r ON r.room_id = b.room_id "
                  "WHERE r.name = 'Room 201' AND b.start_time = %s AND b.status = 'confirmed'", (start,)) == 1


@db_only
def test_scheduled_item_loan_is_cancelled_with_migration_006(db_client):
    bob = user_id("bob.student@example.edu")
    login_as(db_client, bob)
    start, end = free_slot("item", "DEMO-ARD-001", 14)
    post(db_client, "/items/Arduino%20Starter%20Kit/confirmBooking",
         data={"version": "DEMO-ARD-001", "date": start.date().isoformat(), "time": slot(start)})
    loan = scalar("SELECT l.loan_id FROM loans l JOIN items i ON i.item_id = l.item_id "
                  "WHERE i.asset_tag = 'DEMO-ARD-001' AND l.user_id = %s AND l.borrowed_at = %s", (bob, start))
    assert loan is not None
    assert scalar("SELECT due_at FROM loans WHERE loan_id = %s", (loan,)) == end
    login_as(db_client, user_id("alice.student@example.edu"))           # not the owner
    post(db_client, "/cancelBooking", data={"booking_id": str(loan), "kind": "item"})
    assert scalar("SELECT status FROM loans WHERE loan_id = %s", (loan,)) == "active"
    login_as(db_client, bob)
    post(db_client, "/cancelBooking", data={"booking_id": str(loan), "kind": "item"})
    assert scalar("SELECT status FROM loans WHERE loan_id = %s", (loan,)) == "cancelled"
    assert scalar("SELECT returned_at FROM loans WHERE loan_id = %s", (loan,)) is None


@db_only
def test_triggers_record_application_identity(db_client):
    alice = user_id("alice.student@example.edu")
    login_as(db_client, alice)
    start, _ = free_slot("room", "Project Room 12", 80)
    post(db_client, "/rooms/Project%20Room%2012/confirmBooking",
         data={"date": start.date().isoformat(), "time": slot(start), "people": "1"})
    booking = scalar("SELECT b.booking_id FROM bookings b JOIN rooms r ON r.room_id = b.room_id "
                     "WHERE r.name = 'Project Room 12' AND b.start_time = %s AND b.status = 'confirmed'", (start,))
    with connect() as db, db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute("SELECT * FROM audit_events WHERE entity_table='bookings' AND entity_id=%s AND action='INSERT'",
                       (str(booking),))
        row = cursor.fetchone()
    assert row["application_user_id"] == alice
    assert row["event_source"] == "application"
    assert row["database_user"].startswith("campus_app@")
    assert row["connection_id"] is not None


@db_only
def test_registration_by_a_signed_in_visitor_is_stored_as_direct_sql(db_client):
    # The row the trigger really writes, for the case the fake-database test
    # test_registration_by_a_signed_in_visitor_is_not_attributed_to_them covers
    # at the level of the statements: /register sent from a signed-in session.
    alice = user_id("alice.student@example.edu")
    assert alice is not None
    login_as(db_client, alice)
    email = f"signed-in.{time.time_ns()}.{random.randint(0, 10**9)}@example.edu"
    response = post(db_client, "/register", data={
        "full_name": "Registered While Signed In", "email": email, "password": "a-long-password",
        "confirm_password": "a-long-password"})
    assert response.status_code == 302 and response.headers["Location"].endswith("/login")
    with db_client.session_transaction() as s:
        assert s["user_id"] == alice                          # the request was not anonymous
    created = user_id(email)
    assert created is not None and created != alice
    with connect() as db, db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute("SELECT * FROM audit_events WHERE entity_table='users' AND entity_id=%s AND action='INSERT'",
                       (str(created),))
        rows = cursor.fetchall()
    assert len(rows) == 1
    (row,) = rows
    assert row["application_user_id"] is None                 # not alice, although her session sent the form
    assert row["event_source"] == "direct_sql"
    assert row["database_user"].startswith("campus_app@")
    assert row["connection_id"] is not None


@db_only
def test_password_hash_never_copied_into_history():
    with connect() as db, db.cursor() as cursor:
        cursor.execute("SELECT COUNT(*) FROM audit_events WHERE entity_table='users' "
                       "AND (new_values LIKE '%pbkdf2%' OR new_values LIKE '%scrypt%' OR old_values LIKE '%pbkdf2%')")
        assert cursor.fetchone()[0] == 0


@db_only
def test_application_account_cannot_delete_or_forge_history():
    with connect() as db, db.cursor() as cursor:
        with pytest.raises(pymysql.err.OperationalError) as denied:
            cursor.execute("DELETE FROM bookings WHERE booking_id = -1")
        assert denied.value.args[0] == 1142
        with pytest.raises(pymysql.err.OperationalError) as denied_loans:
            cursor.execute("DELETE FROM loans WHERE loan_id = -1")
        assert denied_loans.value.args[0] == 1142
        with pytest.raises(pymysql.err.OperationalError) as forged:
            cursor.execute("INSERT INTO audit_events (action, entity_table, entity_id) VALUES ('DELETE','x','1')")
        assert forged.value.args[0] == 1142


@db_only
def test_application_account_cannot_assign_or_change_administrator_role():
    email = f"role.test.{random.randint(0, 10**9)}@example.edu"
    with connect() as db, db.cursor() as cursor:
        with pytest.raises(pymysql.err.OperationalError) as denied_insert:
            cursor.execute(
                "INSERT INTO users (full_name,email,password_hash,role) VALUES (%s,%s,%s,'admin')",
                ("Role Test", email, "not-a-real-hash"),
            )
        assert denied_insert.value.args[0] == 1143
        with pytest.raises(pymysql.err.OperationalError) as denied_update:
            cursor.execute("UPDATE users SET role='admin' WHERE user_id=1")
        assert denied_update.value.args[0] in (1142, 1143)
        cursor.execute("SELECT COUNT(*) FROM users WHERE email=%s", (email,))
        assert cursor.fetchone()[0] == 0
