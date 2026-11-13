"""Smart Campus: the official university resource booking site, with the
FRANtastic security layer and the campus_audit Audit Lab integrated.

The official pages, URLs, endpoint names and booking rules are unchanged
(rooms and items addressed by name, 09:00-22:00 hourly slots, items up to 14
days ahead, rooms up to 3 calendar months ahead, scheduled item loans).

What the integration adds underneath:

* one database connection per request (flask.g), opened with the
  least-privilege account campus_app from the environment, never root;
* @app_user_id set on every connection, so the audit triggers attribute the
  changes a signed-in user makes for themselves to that user.  Two kinds of
  write are deliberately not attributed to a user: anonymous requests
  (registration) and the housekeeping of expire_finished_reservations(),
  which updates other users' reservations and therefore runs with
  @app_user_id NULL.  The triggers store both with application_user_id NULL
  and event_source 'direct_sql' (docs/design-decisions.md, "Identity");
* booking validation and insertion in one transaction that locks the room or
  item rows (SELECT ... FOR UPDATE), so concurrent attempts serialize;
* CSRF tokens on every state-changing request, a login throttle, inactive-
  account checks, server-side admin checks and hardened session cookies;
* the admin change-history page, the guided Audit Lab and /healthz.

Run locally with `python app.py` (waitress), or import `app` / `create_app`
from a WSGI server.
"""
import calendar
import hmac
import json
import os
import re
import secrets
import threading
import time
from collections import OrderedDict, deque
from datetime import date, datetime, timedelta
from functools import wraps

import pymysql
from dotenv import load_dotenv
from flask import (Flask, abort, current_app, flash, g, jsonify, redirect, render_template, request,
                   session, url_for)
from werkzeug.security import check_password_hash, generate_password_hash

import lab as audit_lab

# Environment first: create_app() reads its configuration from os.environ.
load_dotenv()


# ==========================================
# BOOKING RULES (official)
# ==========================================

ITEM_MAX_DAYS = 14        # items: up to 2 weeks ahead
ROOM_MAX_MONTHS = 3       # rooms: up to 3 months ahead
OPEN_HOUR = 9             # bookable from 09:00 (quiet hours: 22:00 - 09:00)
CLOSE_HOUR = 22           # bookable until 22:00

# Hourly slots, e.g. "09:00 - 10:00"
SLOT_LABELS = [f"{h:02d}:00 - {h + 1:02d}:00" for h in range(OPEN_HOUR, CLOSE_HOUR)]

EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
MAX_NAME_LENGTH = 150
MIN_PASSWORD_LENGTH = 8
AUDIT_PAGE_SIZE = 50
AUDIT_MAX_PAGE = 200

# A valid hash of a random password: verifying against it when an email is
# unknown keeps the login's timing independent of whether the account exists.
_DUMMY_PASSWORD_HASH = generate_password_hash(secrets.token_urlsafe(16))


class BookingError(Exception):
    """A booking or loan request that cannot be fulfilled; shown to the user."""


class DatabaseUnavailable(Exception):
    """The application account could not open a connection to MariaDB."""

    def __init__(self, code, detail):
        super().__init__(detail)
        self.code = code


# What a failed connection usually means in this project, by MariaDB/PyMySQL error code.
# Shown to users: names no password, host credentials or SQL.
DATABASE_HINTS = {
    1045: ("MariaDB rejected the password of the application account campus_app. "
           "This usually means the database volume was created with an earlier .env: MariaDB "
           "applies the passwords only when it initialises an empty volume. Run make doctor; "
           "make repair-credentials sets the stored passwords to .env and keeps all data."),
    1049: "The database university_resources does not exist yet. Run make up (or scripts/setup_database.sh).",
    2003: "MariaDB is not reachable. Is the database running? Run make up, then make doctor.",
    None: "The web app could not connect to MariaDB. Check the DB_* settings in .env and run make doctor.",
}

# The only MariaDB account the web application may use (database/app_account.sh).
APP_DB_ACCOUNT = "campus_app"

CSRF_FIELD = "csrf_token"
CSRF_HEADER = "X-CSRF-Token"
SAFE_METHODS = ("GET", "HEAD", "OPTIONS")


# ==========================================
# LOGIN THROTTLE
# ==========================================

LOGIN_MAX_FAILURES = 5          # failed logins per (address, email) pair ...
LOGIN_IP_MAX_FAILURES = 60      # ... and per address, whatever the email ...
LOGIN_WINDOW_SECONDS = 300      # ... within this rolling window
THROTTLE_MAX_ENTRIES = 10000    # keys one throttle stores at most
LOGIN_KEY_EMAIL_LENGTH = 254    # longest valid address; a longer typed one is cut in the throttle key


class LoginThrottle:
    """Refuses further attempts after repeated failures within a time window.

    In-memory and per process: it slows down password guessing, it is not a
    distributed rate limiter (a restart clears it, and with several worker
    processes each keeps its own counts).

    Memory is bounded in three ways:

    * per key, only the newest max_failures times are kept; older ones cannot
      change the answer of blocked();
    * keys are kept in the order of their most recent failure, so the keys
      whose window has passed are always the first ones.  Every call removes
      them from the front, also keys that are never asked about again; that
      costs time only for the keys it removes, never a sweep of all keys;
    * at most max_entries keys are stored.  A new key that would exceed this
      replaces the key whose most recent failure is the oldest.  That history
      is lost: under a flood of more than max_entries distinct keys within
      one window the throttle forgets the least recently failed ones rather
      than grow or refuse everyone.

    The clock must not run backwards (time.monotonic does not).
    """

    def __init__(self, max_failures=LOGIN_MAX_FAILURES, window_seconds=LOGIN_WINDOW_SECONDS,
                 clock=time.monotonic, max_entries=THROTTLE_MAX_ENTRIES):
        if max_failures < 1 or max_entries < 1:
            raise ValueError("max_failures and max_entries must be at least 1")
        self.max_failures = max_failures
        self.window = window_seconds
        self.clock = clock
        self.max_entries = max_entries
        # key -> its newest failure times (never empty), least recently failed key first
        self._failures = OrderedDict()
        self._lock = threading.Lock()

    def __len__(self):
        """The number of keys stored at the moment."""
        with self._lock:
            return len(self._failures)

    def _drop_expired_keys(self, now):
        while self._failures:
            key = next(iter(self._failures))
            if now - self._failures[key][-1] <= self.window:
                break
            del self._failures[key]

    def blocked(self, key):
        with self._lock:
            now = self.clock()
            self._drop_expired_keys(now)
            recent = self._failures.get(key)
            if recent is None:
                return False
            while recent and now - recent[0] > self.window:
                recent.popleft()
            if not recent:
                del self._failures[key]
            return len(recent) >= self.max_failures

    def record_failure(self, key):
        with self._lock:
            now = self.clock()
            self._drop_expired_keys(now)
            recent = self._failures.get(key)
            if recent is None:
                while len(self._failures) >= self.max_entries:
                    self._failures.popitem(last=False)
                recent = self._failures[key] = deque(maxlen=self.max_failures)
            else:
                self._failures.move_to_end(key)
            recent.append(now)

    def clear(self, key):
        with self._lock:
            self._failures.pop(key, None)


# ==========================================
# CSRF
# ==========================================

def csrf_token():
    """The session's CSRF token, created on first use."""
    token = session.get("_csrf")
    if not token:
        token = secrets.token_urlsafe(32)
        session["_csrf"] = token
    return token


def wants_json():
    return request.path.startswith("/lab/api/") or request.path == "/healthz"


# ==========================================
# APPLICATION FACTORY
# ==========================================

def _env_flag(name):
    return os.getenv(name, "").strip().lower() in ("1", "true", "yes", "on")


def create_app(config=None):
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=os.getenv("SECRET_KEY"),
        DB_HOST=os.getenv("DB_HOST", "127.0.0.1"),
        DB_PORT=int(os.getenv("DB_PORT", "3306")),
        DB_USER=os.getenv("DB_USER", APP_DB_ACCOUNT),
        DB_PASSWORD=os.getenv("DB_PASSWORD"),
        DB_NAME=os.getenv("DB_NAME", "university_resources"),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        # Set SESSION_COOKIE_SECURE=1 when the app is served over HTTPS; plain
        # http://127.0.0.1 development keeps working without it.
        SESSION_COOKIE_SECURE=_env_flag("SESSION_COOKIE_SECURE"),
        PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
    )
    if config:
        app.config.update(config)

    secret = app.config.get("SECRET_KEY")
    if not secret:
        raise RuntimeError("SECRET_KEY is not set; copy .env.example to .env and fill it in")
    if str(secret).startswith("change-me"):
        raise RuntimeError("SECRET_KEY still has the placeholder value from .env.example; set a random value")
    # Exact match: root, any other administrator or maintenance account, an
    # empty value and a differently spelled name are all refused.  There is no
    # second account to fall back to.
    if app.config.get("DB_USER") != APP_DB_ACCOUNT:
        raise RuntimeError(f"DB_USER must be exactly the application account {APP_DB_ACCOUNT}; "
                           "the web app does not run with any other database account")

    # Keep the plugin's field order (ts, seq, instance, event, ...) in JSON responses.
    app.json.sort_keys = False
    # Failed logins: 5 per (address, email) pair and 60 per address, each within 5 minutes.
    app.login_throttle = LoginThrottle(max_failures=LOGIN_MAX_FAILURES, window_seconds=LOGIN_WINDOW_SECONDS)
    app.login_ip_throttle = LoginThrottle(max_failures=LOGIN_IP_MAX_FAILURES, window_seconds=LOGIN_WINDOW_SECONDS)
    # Lab actions per signed-in user: 60 per 5 minutes (each one runs real statements).
    app.lab_throttle = LoginThrottle(max_failures=60, window_seconds=300)
    app.jinja_env.globals["csrf_token"] = csrf_token

    @app.before_request
    def reject_forged_posts():
        """Every state-changing request must carry the token of the session's own forms."""
        if request.method in SAFE_METHODS:
            return None
        sent = request.form.get(CSRF_FIELD) or request.headers.get(CSRF_HEADER) or ""
        expected = session.get("_csrf") or ""
        if not expected or not hmac.compare_digest(sent.encode(), expected.encode()):
            if wants_json():
                return jsonify(error="csrf", message="Missing or invalid CSRF token; reload the page."), 400
            abort(400, description="Missing or invalid CSRF token; reload the page and try again.")
        return None

    @app.errorhandler(DatabaseUnavailable)
    def database_unavailable(e):
        hint = DATABASE_HINTS.get(e.code, DATABASE_HINTS[None])
        if wants_json():
            return jsonify(error="database_unavailable", code=e.code, message=hint), 503
        return render_template("errors/database.html", code=e.code, hint=hint), 503

    @app.errorhandler(pymysql.err.MySQLError)
    def database_error(e):
        # Logged with its traceback; the user sees neither SQL nor server messages.
        current_app.logger.exception("database error during %s %s", request.method, request.path)
        _rollback_quietly()
        if wants_json():
            return jsonify(error="database", message="The database refused the request; see the web app's log."), 500
        return render_template("errors/500.html"), 500

    @app.errorhandler(audit_lab.LabError)
    def lab_error(e):
        return jsonify(error="lab", message=str(e)), e.status

    @app.errorhandler(500)
    def internal_error(e):
        # Flask has already logged the traceback.
        if wants_json():
            return jsonify(error="internal", message="Unexpected server error; see the web app's log."), 500
        return render_template("errors/500.html"), 500

    register_routes(app)
    app.teardown_appcontext(close_db)
    return app


# ==========================================
# DATABASE ACCESS (request-scoped)
# ==========================================

def get_db():
    """The request's database connection, opened on first use.

    The account is always campus_app (DB_USER); @app_user_id tells the audit
    triggers which application user acts, and is set explicitly to NULL for
    anonymous requests instead of relying on any earlier connection state.
    """
    if "db" not in g:
        cfg = current_app.config
        if cfg.get("DB_USER") != APP_DB_ACCOUNT:
            # create_app() already refused this; a configuration changed afterwards is refused here.
            current_app.logger.error("DB_USER is not %s; refusing to connect with another account", APP_DB_ACCOUNT)
            raise DatabaseUnavailable(None, "DB_USER is not the application account")
        if not cfg.get("DB_PASSWORD"):
            current_app.logger.error("DB_PASSWORD is not set; refusing to connect without the campus_app password")
            raise DatabaseUnavailable(None, "DB_PASSWORD is not set")
        try:
            connection = pymysql.connect(
                host=cfg["DB_HOST"],
                port=cfg["DB_PORT"],
                user=APP_DB_ACCOUNT,
                password=cfg["DB_PASSWORD"],
                database=cfg["DB_NAME"],
                charset="utf8mb4",
                autocommit=False,
                connect_timeout=5,
            )
        except pymysql.err.MySQLError as e:
            code = e.args[0] if e.args else None
            # The message names account and host, never the password.
            current_app.logger.error("cannot connect to MariaDB at %s:%s as %s: %s",
                                     cfg["DB_HOST"], cfg["DB_PORT"], APP_DB_ACCOUNT, e)
            raise DatabaseUnavailable(code, str(e)) from e
        try:
            _set_audit_identity(connection, session.get("user_id"))
        except pymysql.err.MySQLError:
            connection.close()
            raise
        g.db = connection
    return g.db


def _set_audit_identity(connection, user_id):
    """Sets @app_user_id, the application user the audit triggers record (None = NULL)."""
    with connection.cursor() as cursor:
        cursor.execute("SET @app_user_id = %s", (user_id,))


def _discard_connection(db):
    """Closes a connection whose session state is uncertain and detaches it from the request.

    A later get_db() in the same request opens a new connection and sets
    @app_user_id again, so the uncertain one can never write.
    """
    if g.get("db") is db:
        g.pop("db", None)
    try:
        db.close()          # the server rolls back whatever was uncommitted
    except Exception:  # noqa: BLE001 - already failing; the caller re-raises
        pass


def _rollback_quietly():
    db = g.get("db")
    if db is not None:
        try:
            db.rollback()
        except pymysql.err.MySQLError:
            current_app.logger.warning("rollback failed", exc_info=True)


def close_db(exception=None):
    """Teardown: undo anything left uncommitted, then discard the connection.

    Every successful write path commits explicitly, so whatever is still open
    here belongs to a failed or abandoned request.  Closing the connection
    discards @app_user_id and every other session variable with it.
    """
    db = g.pop("db", None)
    if db is None:
        return
    try:
        db.rollback()
    except Exception:  # noqa: BLE001 - teardown must never raise
        pass
    finally:
        try:
            db.close()
        except Exception:  # noqa: BLE001
            pass


def expire_finished_reservations(db):
    """Official housekeeping: overdue loans become 'returned', past bookings 'completed'.

    The two UPDATEs touch every user's overdue reservations, so they must not
    be attributed to whoever happens to load the page.  @app_user_id is set
    to NULL for the cleanup and restored to the request's user afterwards,
    whatever happened in between.

    What the triggers then record (database/triggers.sql, unchanged):
    application_user_id NULL, database_user campus_app@..., and event_source
    'direct_sql' - the trigger derives event_source only from whether
    @app_user_id is NULL and has no separate value for application
    housekeeping.

    The cleanup commits on its own; a failure in it is logged and rolled back
    without blocking the page.  If that rollback fails too, the transaction
    state is unknown: the connection is closed at once, without another
    statement on it, and the rollback error propagates.  If @app_user_id
    cannot be restored, the connection is closed and the error propagates as
    well: the request fails rather than continue with an uncertain
    transaction or audit identity.  In both cases the connection is detached
    from the request, so a later get_db() opens a new one.
    """
    request_user_id = session.get("user_id")
    discarded = False
    try:
        try:
            _set_audit_identity(db, None)
            with db.cursor() as cursor:
                cursor.execute(
                    "UPDATE loans SET status = 'returned', returned_at = CURRENT_TIMESTAMP(6) "
                    "WHERE status = 'active' AND due_at < CURRENT_TIMESTAMP(6)")
                cursor.execute(
                    "UPDATE bookings SET status = 'completed' "
                    "WHERE status = 'confirmed' AND end_time < CURRENT_TIMESTAMP(6)")
            db.commit()
        except pymysql.err.MySQLError:
            current_app.logger.warning("error auto-cleaning reservations", exc_info=True)
            try:
                db.rollback()
            except Exception:
                discarded = True
                _discard_connection(db)
                raise
    finally:
        if not discarded:
            try:
                _set_audit_identity(db, request_user_id)
            except Exception:
                _discard_connection(db)
                raise


# ==========================================
# AUTHENTICATION & AUTHORIZATION
# ==========================================

def load_active_user(db, user_id):
    """(role, full_name) of an existing, active account, else None."""
    with db.cursor() as cursor:
        cursor.execute("SELECT role, full_name, is_active FROM users WHERE user_id = %s", (user_id,))
        row = cursor.fetchone()
    if row is None or not row[2]:
        return None
    return row[0], row[1]


def _confirm_account():
    """Re-reads the signed-in account; returns its role, or None after ending a stale session.

    The role in the session is only a cache for the templates: authorization
    decisions use the role and active state stored in the database now.
    """
    account = load_active_user(get_db(), session["user_id"])
    if account is None:
        session.clear()
        return None
    if session.get("role") != account[0]:
        session["role"] = account[0]
    return account[0]


def _api_login_refusal():
    if session.get("user_id") is None or _confirm_account() is None:
        return jsonify(error="login_required", message="Log in to use the live lab."), 401
    return None


def login_required(f):
    """Signed-in and still active; deactivated accounts lose their session."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if session.get("user_id") is None:
            return redirect(url_for("login"))
        if _confirm_account() is None:
            flash("Please log in again.")
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated_function


def admin_required(f):
    """Administrator role, checked on the server against the database."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if session.get("user_id") is None:
            return redirect(url_for("login"))
        if session.get("role") != "admin":
            abort(403)                      # no database needed to refuse a student session
        role = _confirm_account()
        if role is None:
            return redirect(url_for("login"))
        if role != "admin":
            abort(403)
        return f(*args, **kwargs)
    return decorated_function


def api_login_required(f):
    """login_required for the JSON endpoints: 401 instead of a redirect."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        refused = _api_login_refusal()
        if refused:
            return refused
        return f(*args, **kwargs)
    return decorated_function


def is_admin():
    return session.get("role") == "admin"


# ==========================================
# BOOKING RULES & HELPERS
# ==========================================

# Add months to a date (keeps the day valid, e.g. Jan 31 + 1 month = Feb 28)
def add_months(d, months):
    month = d.month - 1 + months
    year = d.year + month // 12
    month = month % 12 + 1
    day = min(d.day, calendar.monthrange(year, month)[1])
    return d.replace(year=year, month=month, day=day)


# Last date a user is allowed to book ("item" or "room")
def last_bookable_date(kind, today=None):
    today = today or date.today()
    if kind == "item":
        return today + timedelta(days=ITEM_MAX_DAYS)
    return add_months(today, ROOM_MAX_MONTHS)


def check_booking_rules(kind, date_str, slot_label, now=None):
    """The official time rules; returns (start, end) or raises BookingError.  No database access."""
    now = now or datetime.now()
    if slot_label not in SLOT_LABELS:
        raise BookingError("Please choose a valid date and time slot.")
    try:
        day = datetime.strptime(date_str, "%Y-%m-%d").date()
        start_str, end_str = slot_label.split(" - ")
        start = datetime.combine(day, datetime.strptime(start_str, "%H:%M").time())
        end = datetime.combine(day, datetime.strptime(end_str, "%H:%M").time())
    except (ValueError, TypeError, AttributeError):
        raise BookingError("Please choose a valid date and time slot.")

    if start < now:
        raise BookingError("You cannot book in the past.")

    if day > last_bookable_date(kind, now.date()):
        if kind == "item":
            raise BookingError(f"Items can only be booked up to {ITEM_MAX_DAYS} days in advance.")
        raise BookingError(f"Rooms can only be booked up to {ROOM_MAX_MONTHS} months in advance.")

    if start.hour < OPEN_HOUR or end > datetime.combine(day, datetime.min.time()).replace(hour=CLOSE_HOUR):
        raise BookingError("You cannot book during quiet hours.")
    return start, end


def _overlap_query(kind, resource_ids, lock):
    marks = ", ".join(["%s"] * len(resource_ids))
    suffix = " FOR UPDATE" if lock else ""
    if kind == "room":
        return ("SELECT COUNT(*) FROM bookings WHERE room_id IN (" + marks + ") "
                "AND status = 'confirmed' AND start_time < %s AND end_time > %s" + suffix)
    return ("SELECT COUNT(*) FROM loans WHERE item_id IN (" + marks + ") "
            "AND status = 'active' AND borrowed_at < %s AND due_at > %s" + suffix)


def _resources(cursor, kind, name, version, lock):
    """[(id, status)] of the named room(s) or item(s), in id order."""
    suffix = " FOR UPDATE" if lock else ""
    if kind == "room":
        cursor.execute("SELECT room_id, status FROM rooms WHERE name = %s ORDER BY room_id" + suffix, (name,))
    elif version:
        cursor.execute("SELECT item_id, status FROM items WHERE name = %s AND asset_tag = %s ORDER BY item_id"
                       + suffix, (name, version))
    else:
        cursor.execute("SELECT item_id, status FROM items WHERE name = %s ORDER BY item_id" + suffix, (name,))
    return list(cursor.fetchall())


def find_conflict(db, kind, name, version, start, end, lock=False):
    """The reason the slot cannot be booked, or None.  Returns (error, resource_id).

    With lock=True the room/item rows and the overlapping reservations are
    read with SELECT ... FOR UPDATE: locking reads see the latest committed
    data and keep competing transactions for the same resource waiting until
    this one commits or rolls back.
    """
    with db.cursor() as cursor:
        resources = _resources(cursor, kind, name, version, lock)
        if not resources:
            return ("This room does not exist." if kind == "room" else "This item does not exist."), None
        ids = [r[0] for r in resources]
        cursor.execute(_overlap_query(kind, ids, lock), ids + [end, start])
        if cursor.fetchone()[0] > 0:
            return "That time slot is already booked.", None
        available = [r[0] for r in resources if r[1] == "available"]
        if not available:
            return ("This room is not available for booking." if kind == "room"
                    else "This item is not available."), None
        return None, available[0]


def validate_booking(kind, name, version, date_str, slot_label):
    """Official helper: (error_message, start, end); error_message is None if valid.

    Read-only check on the request's connection, used by the verify pages.
    The confirm routes repeat it inside the locking transaction.
    """
    try:
        start, end = check_booking_rules(kind, date_str, slot_label)
    except BookingError as e:
        return str(e), None, None
    error, _ = find_conflict(get_db(), kind, name, version, start, end)
    if error:
        return error, None, None
    return None, start, end


def _begin(db):
    # End any read-only snapshot opened earlier in the request (login check,
    # housekeeping) so the transaction starts clean, then open it explicitly.
    db.rollback()
    db.begin()


# Deadlock and lock-wait timeout: the competing booking won; the user may retry.
LOCK_CONFLICT_CODES = (1205, 1213)


def _run_booking(db, work):
    try:
        _begin(db)
        result = work()
        db.commit()
        return result
    except pymysql.err.OperationalError as e:
        db.rollback()
        if e.args and e.args[0] in LOCK_CONFLICT_CODES:
            raise BookingError("Someone else is booking this right now. Please try again.") from e
        raise
    except Exception:
        db.rollback()
        raise


def book_room(db, user_id, room_name, start, end):
    """Creates a confirmed room booking; returns its id or raises BookingError.

    Check and INSERT run in one transaction that locks the room row(s), so two
    requests for the same room serialize and the second one sees the first
    one's booking.  Any failure rolls the whole transaction back.
    """
    def work():
        error, room_id = find_conflict(db, "room", room_name, None, start, end, lock=True)
        if error:
            raise BookingError(error)
        with db.cursor() as cursor:
            cursor.execute(
                "INSERT INTO bookings (user_id, room_id, start_time, end_time, status) "
                "VALUES (%s, %s, %s, %s, 'confirmed')",
                (user_id, room_id, start, end))
            return cursor.lastrowid
    return _run_booking(db, work)


def book_item(db, user_id, item_name, version, start, end):
    """Creates a scheduled loan (borrowed_at = slot start, due_at = slot end).

    Same transaction and locking scheme as book_room, on the item row(s).
    """
    def work():
        error, item_id = find_conflict(db, "item", item_name, version, start, end, lock=True)
        if error:
            raise BookingError(error)
        with db.cursor() as cursor:
            cursor.execute(
                "INSERT INTO loans (user_id, item_id, borrowed_at, due_at, status) "
                "VALUES (%s, %s, %s, %s, 'active')",
                (user_id, item_id, start, end))
            return cursor.lastrowid
    return _run_booking(db, work)


def cancel_reservation(db, user_id, kind, reservation_id):
    """Cancels the user's own reservation; returns a message for the user.

    Rooms: a confirmed booking becomes 'cancelled'.
    Items: a loan that has not started becomes 'cancelled' (migration 006; the
    row, its dates and its history stay); a loan that already started is
    returned (status 'returned', returned_at = now), as before.
    Nothing is deleted, and only the owner's rows match.
    """
    try:
        reservation_id = int(reservation_id)
    except (TypeError, ValueError):
        return "This booking cannot be cancelled."
    try:
        with db.cursor() as cursor:
            if kind == "room":
                cursor.execute(
                    "UPDATE bookings SET status = 'cancelled' "
                    "WHERE booking_id = %s AND user_id = %s AND status = 'confirmed'",
                    (reservation_id, user_id))
                message = "Booking cancelled." if cursor.rowcount else "This booking cannot be cancelled."
            elif kind == "item":
                cursor.execute(
                    "UPDATE loans SET status = 'cancelled' "
                    "WHERE loan_id = %s AND user_id = %s AND status = 'active' "
                    "AND borrowed_at > CURRENT_TIMESTAMP(6)",
                    (reservation_id, user_id))
                if cursor.rowcount:
                    message = "Booking cancelled."
                else:
                    cursor.execute(
                        "UPDATE loans SET status = 'returned', returned_at = CURRENT_TIMESTAMP(6) "
                        "WHERE loan_id = %s AND user_id = %s AND status = 'active' "
                        "AND borrowed_at <= CURRENT_TIMESTAMP(6)",
                        (reservation_id, user_id))
                    message = "Item returned." if cursor.rowcount else "This booking cannot be cancelled."
            else:
                return "This booking cannot be cancelled."
        db.commit()
        return message
    except Exception:
        db.rollback()
        raise


# Bookings as Calendar Events (green = yours, red = other users, grey = past)
def get_events(kind, name):
    events = []
    current_user_id = session.get("user_id")
    with get_db().cursor(pymysql.cursors.DictCursor) as cursor:
        if kind == "room":
            cursor.execute(
                "SELECT b.start_time, b.end_time, b.user_id, b.status, NULL AS version "
                "FROM bookings b JOIN rooms r ON b.room_id = r.room_id "
                "WHERE r.name = %s AND b.status IN ('confirmed', 'completed')", (name,))
        else:
            cursor.execute(
                "SELECT l.borrowed_at AS start_time, l.due_at AS end_time, l.user_id, l.status, "
                "       i.asset_tag AS version "
                "FROM loans l JOIN items i ON l.item_id = i.item_id "
                "WHERE i.name = %s AND l.status IN ('active', 'returned')", (name,))
        rows = cursor.fetchall()

    for row in rows:
        if row["start_time"] is None or row["end_time"] is None:
            continue
        mine = row["user_id"] == current_user_id
        is_past = row["status"] in ("completed", "returned")

        # Determine color and title
        if is_past:
            color = "#8b8b8b" if mine else "#484848"
            title = "Completed" if mine else "Booked (Past)"
        else:
            color = "#198733" if mine else "#e73a3a"
            title = "Your Booking" if mine else "Booked"

        if row["version"]:
            title += f" ({row['version']})"

        events.append({
            "title": title,
            "start": row["start_time"].isoformat(),
            "end": row["end_time"].isoformat(),
            "color": color,
        })
    return events


# Everything the booking pages and the calendar need
def booking_context(kind, name, error=None):
    return {
        "slots": SLOT_LABELS,
        "min_date": date.today().isoformat(),
        "max_date": last_bookable_date(kind).isoformat(),
        "slot_min": f"{OPEN_HOUR:02d}:00:00",
        "slot_max": f"{CLOSE_HOUR:02d}:00:00",
        "events": get_events(kind, name),
        "error": error,
    }


# ==========================================
# AUDIT PAGE HELPERS
# ==========================================

def _json_text(value):
    """old_values/new_values for display: pretty JSON when parseable, else the raw text."""
    if value is None or value == "":
        return ""
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    try:
        return json.dumps(json.loads(value), indent=1, ensure_ascii=False, sort_keys=True)
    except (TypeError, ValueError):
        return str(value)


def _page_number(raw):
    try:
        page = int(raw)
    except (TypeError, ValueError):
        return 1
    return min(max(page, 1), AUDIT_MAX_PAGE)


# ==========================================
# ROUTES
# ==========================================

def register_routes(app):

    # ==========================================
    # HOME & LAB PAGES
    # ==========================================

    # Homepage
    @app.route("/")
    def index():
        return render_template("index.html")

    # Audit Lab: guided tour with live plugin records (public page; live steps need a login)
    @app.route("/lab")
    def lab():
        return render_template("lab.html", actions=audit_lab.ACTIONS, event_types=audit_lab.EVENT_TYPES,
                               history_tables=audit_lab.HISTORY_TABLES)

    # ==========================================
    # ACCOUNT PAGES
    # ==========================================

    # Account Profile Page
    @app.route("/accountProfile")
    @login_required
    def account_profile():
        with get_db().cursor() as cursor:
            cursor.execute("SELECT full_name FROM users WHERE user_id = %s", (session["user_id"],))
            user = cursor.fetchone()
        return render_template("account/accountProfile.html", user_name=user[0])

    # Account Bookings Page
    @app.route("/accountBookings")
    @login_required
    def account_bookings():
        db = get_db()
        expire_finished_reservations(db)
        my_bookings = []
        user_id = session["user_id"]
        with db.cursor(pymysql.cursors.DictCursor) as cursor:
            # Room Bookings
            cursor.execute(
                "SELECT b.booking_id, r.name, r.capacity, b.start_time, b.end_time "
                "FROM bookings b JOIN rooms r ON b.room_id = r.room_id "
                "WHERE b.user_id = %s AND b.status = 'confirmed' ORDER BY b.start_time", (user_id,))
            for r in cursor.fetchall():
                my_bookings.append({
                    "id": r["booking_id"],
                    "title": f"Room: {r['name']}",
                    "kind": "room",
                    "details": f"Date: {r['start_time'].strftime('%b %d, %Y')}",
                    "details2": f"Time: {r['start_time'].strftime('%H:%M')} - {r['end_time'].strftime('%H:%M')}",
                    "details3": f"Capacity: {r['capacity']} people",
                    "icon": "&#128682;",
                })

            # Item Loans
            cursor.execute(
                "SELECT l.loan_id, i.name, i.asset_tag, l.borrowed_at, l.due_at "
                "FROM loans l JOIN items i ON l.item_id = i.item_id "
                "WHERE l.user_id = %s AND l.status = 'active' ORDER BY l.borrowed_at", (user_id,))
            for i in cursor.fetchall():
                due = i["due_at"]
                my_bookings.append({
                    "id": i["loan_id"],
                    "title": f"Item: {i['name']}",
                    "kind": "item",
                    "details": f"Date: {i['borrowed_at'].strftime('%b %d, %Y')}",
                    "details2": f"Time: {i['borrowed_at'].strftime('%H:%M')} - "
                                f"{due.strftime('%H:%M') if due else 'open'}",
                    "details3": f"Version: {i['asset_tag']}",
                    "icon": "&#128230;",
                })
        return render_template("account/accountBookings.html", bookings=my_bookings)

    # Account Settings Page
    @app.route("/accountSettings", methods=["GET", "POST"])
    @login_required
    def account_settings():
        message = error = None
        db = get_db()
        user_id = session["user_id"]

        if request.method == "POST":
            action = request.form.get("action")

            # Change Name
            if action == "name":
                new_name = (request.form.get("full_name") or "").strip()
                if not new_name:
                    error = "Name cannot be empty."
                elif len(new_name) > MAX_NAME_LENGTH:
                    error = f"Name can have at most {MAX_NAME_LENGTH} characters."
                else:
                    try:
                        with db.cursor() as cursor:
                            cursor.execute("UPDATE users SET full_name = %s WHERE user_id = %s",
                                           (new_name, user_id))
                        db.commit()
                    except Exception:
                        db.rollback()
                        raise
                    session["full_name"] = new_name
                    message = "Name updated."

            # Change Password
            elif action == "password":
                new_password = request.form.get("new_password") or ""
                with db.cursor() as cursor:
                    cursor.execute("SELECT password_hash FROM users WHERE user_id = %s", (user_id,))
                    current_hash = cursor.fetchone()[0]

                if not check_password_hash(current_hash, request.form.get("current_password") or ""):
                    error = "Current password is incorrect."
                elif new_password != request.form.get("confirm_password"):
                    error = "New passwords do not match."
                elif len(new_password) < MIN_PASSWORD_LENGTH:
                    error = f"New password must be at least {MIN_PASSWORD_LENGTH} characters."
                else:
                    try:
                        with db.cursor() as cursor:
                            cursor.execute("UPDATE users SET password_hash = %s WHERE user_id = %s",
                                           (generate_password_hash(new_password), user_id))
                        db.commit()
                    except Exception:
                        db.rollback()
                        raise
                    message = "Password updated."
            else:
                error = "Unknown action."

        with db.cursor() as cursor:
            cursor.execute("SELECT full_name, email FROM users WHERE user_id = %s", (user_id,))
            user = cursor.fetchone()
        return render_template("account/accountSettings.html", user=user, message=message, error=error)

    # ==========================================
    # AUTHENTICATION
    # ==========================================

    # Login Page
    @app.route("/login", methods=["GET", "POST"])
    def login():
        if request.method == "POST":
            user_email = (request.form.get("email") or "").strip()
            user_password = request.form.get("password") or ""

            # Keyed by address and the email as typed: the same answer whether or not the account exists.
            # The address is the peer of the connection (request.remote_addr); forwarding
            # headers are not read, a client could put anything into them.
            address = request.remote_addr
            throttle_key = (address, user_email[:LOGIN_KEY_EMAIL_LENGTH].lower())
            # Second limit per address, over all emails: trying many different
            # emails does not get around the limit of the pair.
            if (current_app.login_throttle.blocked(throttle_key)
                    or current_app.login_ip_throttle.blocked(address)):
                return render_template(
                    "login.html", error="Too many failed attempts. Please wait a few minutes."), 429

            with get_db().cursor() as cursor:
                cursor.execute(
                    "SELECT user_id, password_hash, role, full_name, is_active FROM users WHERE email = %s",
                    (user_email,))
                user = cursor.fetchone()

            # Always verify a hash, so an unknown email costs as much time as a known one.
            password_ok = check_password_hash(user[1] if user else _DUMMY_PASSWORD_HASH, user_password)
            if user and password_ok and user[4]:
                # Only the pair is cleared: the failures of the address stay counted.
                current_app.login_throttle.clear(throttle_key)
                # New session at the authentication boundary: drops every earlier value,
                # including the pre-login CSRF token (a fresh one is issued on next use).
                session.clear()
                session.permanent = True
                session["user_id"] = user[0]
                session["role"] = user[2]
                session["full_name"] = user[3]
                csrf_token()
                # Only this one named target, so the parameter cannot become an open redirect.
                if request.args.get("next") == "lab":
                    return redirect(url_for("lab"))
                return redirect(url_for("index"))

            # Wrong password, unknown email and deactivated account look the same.
            current_app.login_throttle.record_failure(throttle_key)
            current_app.login_ip_throttle.record_failure(address)
            return render_template("login.html", error="Invalid email or password"), 401

        return render_template("login.html")

    # Logout (POST with CSRF token; a GET link could be triggered by any page)
    @app.route("/logout", methods=["POST"])
    def logout():
        session.clear()
        flash("You have been logged out.")
        return redirect(url_for("index"))

    # Register Page
    @app.route("/register", methods=["GET", "POST"])
    def register():
        if request.method == "POST":
            # Only these four fields are read: role and is_active come from the
            # database defaults (student, active), whatever else the form sends.
            user_name = (request.form.get("full_name") or "").strip()
            user_email = (request.form.get("email") or "").strip().lower()
            user_password = request.form.get("password") or ""
            user_confirm_password = request.form.get("confirm_password") or ""

            error = None
            if not user_name or len(user_name) > MAX_NAME_LENGTH:
                error = f"Please enter your name (at most {MAX_NAME_LENGTH} characters)."
            elif not EMAIL_PATTERN.match(user_email) or len(user_email) > 254:
                error = "Please enter a valid email address."
            elif len(user_password) < MIN_PASSWORD_LENGTH:
                error = f"Passwords need at least {MIN_PASSWORD_LENGTH} characters."
            elif user_password != user_confirm_password:
                error = "Passwords do not match"
            if error:
                return render_template("register.html", error=error), 400

            db = get_db()
            try:
                # /register is open to signed-in visitors too: the new account
                # must not be attributed to them (application_user_id NULL,
                # event_source 'direct_sql').  Not restored afterwards: the
                # connection is request-scoped and closed at teardown.
                _set_audit_identity(db, None)
                with db.cursor() as cursor:
                    cursor.execute(
                        "INSERT INTO users (full_name, email, password_hash) VALUES (%s, %s, %s)",
                        (user_name, user_email, generate_password_hash(user_password)))
                db.commit()
            except pymysql.err.IntegrityError:
                db.rollback()
                return render_template("register.html", error="This email is already registered"), 400
            except Exception:
                db.rollback()
                raise

            flash("Account created. Please log in.")
            return redirect(url_for("login"))

        return render_template("register.html")

    # ==========================================
    # ITEMS TO LOAN
    # ==========================================

    # Items Homepage
    @app.route("/itemsHome")
    @login_required
    def items_home():
        inventory_data = {
            "Cleaning Items": ["Vacuum", "Mop", "Iron", "Broom"],

            "Board Games": ["Chess", "Monopoly", "Settlers of Catan", "Scrabble", "Battleship"],

            "Sports Items": ["Basketball", "Football", "Frisbee", "Tennis Racket"],

            "Electronics": ["Speaker", "PS5 Controller", "Headphones", "Nintendo Switch", "Gameboy"]
        }

        return render_template("items/itemsHome.html", inventory=inventory_data)

    # Booking Item
    @app.route("/items/<item_name>")
    @login_required
    def item_booking(item_name):
        expire_finished_reservations(get_db())
        return render_template("items/itemBooking.html", item_name=item_name,
                               **booking_context("item", item_name))

    # Verify Booking Item
    @app.route("/items/<item_name>/verifyBooking", methods=["POST"])
    @login_required
    def verify_item_booking(item_name):
        error, _, _ = validate_booking("item", item_name, request.form.get("version"),
                                       request.form.get("date"), request.form.get("time"))
        if error:
            return render_template("items/itemBooking.html", item_name=item_name,
                                   **booking_context("item", item_name, error))

        return render_template("items/verifyItemBooking.html", item_name=item_name)

    # Confirm Booking Item (saves booking, goes back to Items Homepage)
    @app.route("/items/<item_name>/confirmBooking", methods=["POST"])
    @login_required
    def confirm_item_booking(item_name):
        try:
            start, end = check_booking_rules("item", request.form.get("date"), request.form.get("time"))
            book_item(get_db(), session["user_id"], item_name, request.form.get("version"), start, end)
        except BookingError as e:
            return render_template("items/itemBooking.html", item_name=item_name,
                                   **booking_context("item", item_name, str(e)))
        flash("Booking confirmed.")
        return redirect(url_for("items_home"))

    # ==========================================
    # ROOMS TO BOOK
    # ==========================================

    # Rooms Homepage
    @app.route("/roomsHome")
    @login_required
    def rooms_home():
        rooms_data = ["Study Room", "Meeting Room", "Studio Room", "Practice Room", "Cinema Room"]

        return render_template("rooms/roomsHome.html", rooms=rooms_data)

    # Booking Room
    @app.route("/rooms/<room_name>")
    @login_required
    def room_booking(room_name):
        expire_finished_reservations(get_db())
        return render_template("rooms/roomBooking.html", room_name=room_name,
                               **booking_context("room", room_name))

    # Verify Booking Room
    @app.route("/rooms/<room_name>/verifyBooking", methods=["POST"])
    @login_required
    def verify_room_booking(room_name):
        error, _, _ = validate_booking("room", room_name, None,
                                       request.form.get("date"), request.form.get("time"))
        if error:
            return render_template("rooms/roomBooking.html", room_name=room_name,
                                   **booking_context("room", room_name, error))

        return render_template("rooms/verifyRoomBooking.html", room_name=room_name)

    # Confirm Booking Room (saves booking, goes back to Rooms Homepage)
    @app.route("/rooms/<room_name>/confirmBooking", methods=["POST"])
    @login_required
    def confirm_room_booking(room_name):
        try:
            start, end = check_booking_rules("room", request.form.get("date"), request.form.get("time"))
            book_room(get_db(), session["user_id"], room_name, start, end)
        except BookingError as e:
            return render_template("rooms/roomBooking.html", room_name=room_name,
                                   **booking_context("room", room_name, str(e)))
        flash("Booking confirmed.")
        return redirect(url_for("rooms_home"))

    # ==========================================
    # CANCEL BOOKINGS
    # ==========================================

    @app.route("/cancelBooking", methods=["POST"])
    @login_required
    def cancel_booking():
        message = cancel_reservation(get_db(), session["user_id"], request.form.get("kind"),
                                     request.form.get("booking_id"))
        flash(message)
        return redirect(url_for("account_bookings"))

    # ==========================================
    # ADMINISTRATION: CHANGE HISTORY (read-only)
    # ==========================================

    @app.route("/admin/audit")
    @admin_required
    def admin_audit():
        page = _page_number(request.args.get("page"))
        offset = (page - 1) * AUDIT_PAGE_SIZE
        db = get_db()
        row_changes, history_error = [], None
        plugin_status, plugin_events, plugin_error = [], [], None

        with db.cursor(pymysql.cursors.DictCursor) as cursor:
            try:
                cursor.execute(
                    "SELECT event_id, event_time, action, entity_table, entity_id, database_user, "
                    "       application_user_id, event_source, connection_id, old_values, new_values "
                    "FROM audit_events ORDER BY event_id DESC LIMIT %s OFFSET %s",
                    (AUDIT_PAGE_SIZE + 1, offset))
                row_changes = list(cursor.fetchall())
            except pymysql.err.MySQLError as e:
                current_app.logger.warning("audit_events not readable: %s", e)
                history_error = "The row history (audit_events) is not readable right now."
            try:
                cursor.execute("SHOW GLOBAL STATUS LIKE 'campus\\_audit\\_%'")
                plugin_status = list(cursor.fetchall())
            except pymysql.err.MySQLError as e:
                current_app.logger.warning("plugin status not readable: %s", e)
            try:
                cursor.execute(
                    "SELECT event_time, event_type, schema_name, table_name, db_user, connection_id, "
                    "       query_id, statement_error_code, sql_digest "
                    "FROM campus_audit.v_table_activity ORDER BY event_time DESC LIMIT %s OFFSET %s",
                    (AUDIT_PAGE_SIZE, offset))
                plugin_events = list(cursor.fetchall())
            except pymysql.err.MySQLError as e:
                current_app.logger.warning("plugin records not readable: %s", e)
                plugin_error = ("Plugin records are not readable (is the campus_audit schema installed?). "
                                "Import them in the Audit Lab or with CALL campus_audit.import_current_log().")
        db.rollback()   # read-only page: end the snapshot

        has_next = len(row_changes) > AUDIT_PAGE_SIZE or len(plugin_events) == AUDIT_PAGE_SIZE
        row_changes = row_changes[:AUDIT_PAGE_SIZE]
        for row in row_changes:
            row["old_text"] = _json_text(row.get("old_values"))
            row["new_text"] = _json_text(row.get("new_values"))
        return render_template("admin/audit.html", row_changes=row_changes, history_error=history_error,
                               plugin_status=plugin_status, plugin_events=plugin_events,
                               plugin_error=plugin_error, page=page,
                               has_next=has_next and page < AUDIT_MAX_PAGE)

    # ==========================================
    # HEALTH CHECK (used by the Compose healthcheck and make doctor)
    # ==========================================

    @app.route("/healthz")
    def healthz():
        """200 only if the application account can log in and read the schema.  Read-only."""
        try:
            with get_db().cursor() as cursor:
                cursor.execute("SELECT COUNT(*) FROM users")
                cursor.fetchone()
        except DatabaseUnavailable as e:
            return jsonify(status="error", database="login failed", code=e.code), 503
        except pymysql.err.MySQLError as e:
            return jsonify(status="error", database="schema not readable",
                           code=e.args[0] if e.args else None), 503
        return jsonify(status="ok", database="ok")

    # ==========================================
    # AUDIT LAB API
    # ==========================================

    @app.route("/lab/api/plugin")
    @api_login_required
    def lab_plugin():
        return jsonify(audit_lab.plugin_state(get_db()))

    @app.route("/lab/api/notes")
    @api_login_required
    def lab_notes():
        return jsonify(notes=audit_lab.notes_of(get_db(), session["user_id"]))

    def lab_throttled():
        key = session["user_id"]
        if current_app.lab_throttle.blocked(key):
            return jsonify(error="throttled", message="Too many lab actions; wait a few minutes."), 429
        current_app.lab_throttle.record_failure(key)   # counts every action, not only failures
        return None

    def lab_request_data():
        data = request.get_json(silent=True)
        return data if isinstance(data, dict) else request.form

    @app.route("/lab/api/action", methods=["POST"])
    def lab_action():
        # Validated before any database access (and before the login check
        # touches the database), so malformed requests never reach MariaDB.
        if session.get("user_id") is None:
            return jsonify(error="login_required", message="Log in to use the live lab."), 401
        refused = lab_throttled()
        if refused:
            return refused
        data = lab_request_data()
        action = audit_lab.parse_action(data.get("action"))
        label = audit_lab.parse_label(data.get("label") or "Lab sample") if action in ("create", "violate") else None
        raw_quantity = data.get("quantity")
        quantity = audit_lab.parse_quantity(1 if raw_quantity is None else raw_quantity) \
            if action in ("create", "update", "rollback") else None
        refused = _api_login_refusal()      # active account, checked against the database
        if refused:
            return refused
        result = audit_lab.perform(get_db(), session["user_id"], action, label, quantity, current_app.config)
        journal = session.get("lab_journal", []) + audit_lab.journal_entry(result)
        session["lab_journal"] = journal[-audit_lab.JOURNAL_SIZE:]
        return jsonify(result)

    @app.route("/lab/api/import", methods=["POST"])
    @api_login_required
    def lab_import():
        refused = lab_throttled()
        if refused:
            return refused
        return jsonify(audit_lab.import_log(get_db()))

    @app.route("/lab/api/reset", methods=["POST"])
    @api_login_required
    def lab_reset():
        refused = lab_throttled()
        if refused:
            return refused
        removed = audit_lab.reset(get_db(), session["user_id"])
        return jsonify(removed=removed, notes=[])

    @app.route("/lab/api/events")
    @api_login_required
    def lab_events():
        everything = is_admin() and request.args.get("scope") == "all"
        journal = None if everything else session.get("lab_journal", [])
        events = audit_lab.explore_events(get_db(), request.args, journal)
        return jsonify(events=events, scope="all" if everything else "mine")

    @app.route("/lab/api/history")
    @api_login_required
    def lab_history():
        everything = is_admin() and request.args.get("scope") == "all"
        rows = audit_lab.explore_history(get_db(), request.args, None if everything else session["user_id"])
        return jsonify(history=rows, scope="all" if everything else "mine")


# ==========================================
# ENTRYPOINTS
# ==========================================

_default_app = None


def __getattr__(name):
    """`from app import app` (WSGI servers, `flask --app app`) builds the app on first use.

    Created lazily so that importing this module (tests) does not
    require SECRET_KEY; using the application object without it still fails
    loudly in create_app().
    """
    global _default_app
    if name == "app":
        if _default_app is None:
            _default_app = create_app()
        return _default_app
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


if __name__ == "__main__":
    # waitress: a production WSGI server in pure Python (also on Windows).  Flask's
    # development server, and with it debug mode, is not used.
    from waitress import serve
    serve(create_app(), host=os.getenv("FLASK_HOST", "127.0.0.1"), port=int(os.getenv("FLASK_PORT", "5080")),
          threads=8, ident="campus-audit")
