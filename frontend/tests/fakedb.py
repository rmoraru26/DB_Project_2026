"""An in-memory stand-in for the MariaDB connection the web app opens.

It is not a SQL engine: it recognises exactly the statements frontend/app.py
and frontend/lab.py send (unknown SQL fails the test), keeps rows in Python
lists, and models what the tests need to observe:

* every statement, commit, rollback, begin and close, per connection;
* @app_user_id per connection, recorded with every write statement at the
  moment it executes (`writes` is a log of executed statements: an entry
  stays there when the transaction is rolled back later);
* transactions: writes are undone on rollback; a rollback made to fail
  (`fail_rollback`) undoes nothing, and the transaction stays pending until
  the connection is closed;
* row locks for SELECT ... FOR UPDATE and for the lab's UPDATE/DELETE, held
  until commit/rollback/close, so two threads booking the same resource
  really serialize;
* the campus_app grant contract: statements outside it raise the same
  errors MariaDB would (1142/1143), so a privilege regression fails a test;
* the Audit Lab's table audit_lab_notes with its owner filters and its
  quantity CHECK, and a login as the lab's decoy account that is refused
  with ER 1045 while campus_app connections keep working.

What it deliberately does not model: the campus_audit plugin and the audit
triggers.  It never produces plugin records or audit_events rows; the lab's
queries for them return an empty result.  A test passing against this module
says how the application behaves, never that MariaDB's plugin, triggers,
grants or row locking work.  Those are covered by the RUN_DB_TESTS=1 groups,
which need the real server and do not use this module.
"""
import contextlib
import itertools
import re
import secrets
import threading
from datetime import datetime

import pymysql
from werkzeug.security import generate_password_hash


def norm(sql):
    return " ".join(sql.split())


# lab.INTRUDER_ACCOUNT: the locked decoy account of the lab's failed-login action.
INTRUDER_ACCOUNT = "audit_lab_intruder"

# The exact statements of frontend/lab.py against audit_lab_notes and the audit stores.
LAB_MARKER = "SELECT CONNECTION_ID(), NOW(6)"
LAB_LATEST_NOTE = ("SELECT note_id, label, quantity FROM audit_lab_notes WHERE owner_user_id = %s "
                   "ORDER BY note_id DESC LIMIT 1")
LAB_LIST_NOTES = ("SELECT note_id, label, quantity, created_at, updated_at FROM audit_lab_notes "
                  "WHERE owner_user_id = %s ORDER BY note_id DESC LIMIT 20")
LAB_NOTE_QUANTITY = "SELECT quantity FROM audit_lab_notes WHERE note_id = %s"
LAB_INSERT = "INSERT INTO audit_lab_notes (owner_user_id, label, quantity) VALUES (%s, %s, %s)"
LAB_INSERT_INVALID = "INSERT INTO audit_lab_notes (owner_user_id, label, quantity) VALUES (%s, %s, 0)"
LAB_UPDATE = "UPDATE audit_lab_notes SET quantity = %s WHERE note_id = %s AND owner_user_id = %s"
LAB_DELETE = "DELETE FROM audit_lab_notes WHERE note_id = %s AND owner_user_id = %s"
LAB_RESET = "DELETE FROM audit_lab_notes WHERE owner_user_id = %s"
LAB_PLUGIN_EVENTS = ("SELECT instance_id, seq, event_time, event_type, connection_id, query_id, db_user, "
                     "client_host, schema_name, table_name, status_code, sql_digest, record "
                     "FROM campus_audit.plugin_events ")
LAB_EVENTS_OF_CONNECTION = (LAB_PLUGIN_EVENTS + "WHERE connection_id = %s AND event_time BETWEEN %s AND %s "
                            "ORDER BY instance_id, seq")
LAB_FAILED_LOGINS = (LAB_PLUGIN_EVENTS + "WHERE event_type = 'connect_failed' AND db_user = %s "
                     "AND event_time BETWEEN %s AND %s ORDER BY instance_id, seq")
LAB_HISTORY_OF_CONNECTION = ("SELECT event_id, event_time, action, entity_table, entity_id, database_user, "
                             "application_user_id, event_source, connection_id, old_values, new_values "
                             "FROM audit_events WHERE connection_id = %s AND event_time BETWEEN %s AND %s "
                             "ORDER BY event_id")


class Result:
    def __init__(self, rows=(), rowcount=None, lastrowid=None):
        self.rows = list(rows)
        self.rowcount = len(self.rows) if rowcount is None else rowcount
        self.lastrowid = lastrowid


class FakeCursor:
    def __init__(self, conn, as_dict):
        self.conn, self.as_dict = conn, as_dict
        self.rows, self.rowcount, self.lastrowid = [], 0, None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def close(self):
        pass

    def execute(self, sql, args=None):
        if self.conn.closed:
            raise pymysql.err.InterfaceError(0, "connection closed")
        text = norm(sql)
        args = tuple(args) if isinstance(args, (list, tuple)) else ((args,) if args is not None else ())
        self.conn.statements.append((text, args))
        self.conn.events.append(("execute", text))
        result = self.conn.db.respond(self.conn, text, args)
        rows = result.rows
        if not self.as_dict:
            rows = [tuple(r.values()) if isinstance(r, dict) else r for r in rows]
        self.rows, self.rowcount, self.lastrowid = list(rows), result.rowcount, result.lastrowid
        return self.rowcount

    def fetchone(self):
        return self.rows.pop(0) if self.rows else None

    def fetchall(self):
        rows, self.rows = self.rows, []
        return rows

    def nextset(self):
        return None


class FakeConnection:
    def __init__(self, db, kwargs):
        self.db, self.kwargs = db, kwargs
        self.statements, self.events = [], []
        self.app_user_id = "unset"          # MariaDB: an unset user variable is NULL; "unset" lets tests see it
        self.undo = []
        self.closed = False
        self.id = next(db.connection_ids)

    def cursor(self, cursor_class=None):
        return FakeCursor(self, cursor_class is pymysql.cursors.DictCursor)

    def begin(self):
        self.events.append(("begin",))

    def commit(self):
        self.events.append(("commit",))
        if self.db.fail_commit is not None:
            # The transaction stays open: the application has to roll it back.
            error, self.db.fail_commit = self.db.fail_commit, None
            raise error
        self.undo.clear()
        self.db.release(self)

    def rollback(self):
        self.events.append(("rollback",))
        if self.db.fail_rollback is not None:
            # Nothing is undone and no lock released: the transaction stays
            # pending until close(), as on a server that never saw the ROLLBACK.
            error, self.db.fail_rollback = self.db.fail_rollback, None
            raise error
        while self.undo:
            self.undo.pop()()
        self.db.release(self)

    def close(self):
        if not self.closed:
            self.events.append(("close",))
            # Closing without commit: the server rolls back.
            while self.undo:
                self.undo.pop()()
            self.db.release(self)
            self.closed = True

    # helpers for tests
    def executed(self, pattern):
        return [s for s, _ in self.statements if re.search(pattern, s)]


class FakeDatabase:
    """Shared state of all fake connections of one test."""

    def __init__(self):
        self.users = {}
        self.rooms = []
        self.items = []
        self.bookings = []
        self.loans = []
        self.audit_events = []
        self.lab_notes = []                  # audit_lab_notes rows
        self.intruder_attempts = []          # connect() arguments of logins as INTRUDER_ACCOUNT, without password
        self.reject_intruder = True          # False: the decoy login is (unexpectedly) accepted
        self.writes = []                     # (connection id, @app_user_id, statement), in execution order
        self.connections = []
        self.connection_ids = itertools.count(100)
        self.ids = itertools.count(1000)
        self.fail_connect = None             # pymysql error to raise on connect
        self.audit_error = None              # error for SELECT ... FROM audit_events
        self.plugin_installed = True
        self.plugin_status = [{"Variable_name": "Campus_audit_state", "Value": "ACTIVE"}]
        # (regex or callable(conn, statement, args), exception): raised once, by the first statement that matches
        self.fail_statement = None
        self.fail_commit = None              # exception raised once, by the next commit
        self.fail_rollback = None            # exception raised once, by the next rollback (attempt still logged)
        self.slow_after_lock = None          # callable run after a FOR UPDATE, to widen race windows
        self._locks = {}
        self._cond = threading.Condition()

    # ---------------------------------------------------------------- fixtures

    def add_user(self, email, password="correct-horse-battery", role="student", active=True, name="Test User"):
        user_id = next(self.ids)
        self.users[user_id] = {"user_id": user_id, "full_name": name, "email": email,
                               "password_hash": generate_password_hash(password), "role": role,
                               "is_active": 1 if active else 0}
        return user_id

    def add_room(self, name, status="available", capacity=6):
        room = {"room_id": next(self.ids), "name": name, "status": status, "capacity": capacity}
        self.rooms.append(room)
        return room["room_id"]

    def add_item(self, name, asset_tag, status="available"):
        item = {"item_id": next(self.ids), "name": name, "asset_tag": asset_tag, "status": status}
        self.items.append(item)
        return item["item_id"]

    def add_booking(self, user_id, room_id, start, end, status="confirmed"):
        booking = {"booking_id": next(self.ids), "user_id": user_id, "room_id": room_id,
                   "start_time": start, "end_time": end, "status": status}
        self.bookings.append(booking)
        return booking["booking_id"]

    def add_loan(self, user_id, item_id, borrowed_at, due_at, status="active", returned_at=None):
        loan = {"loan_id": next(self.ids), "user_id": user_id, "item_id": item_id, "borrowed_at": borrowed_at,
                "due_at": due_at, "returned_at": returned_at, "status": status}
        self.loans.append(loan)
        return loan["loan_id"]

    def add_note(self, owner_user_id, label="Lab sample", quantity=1):
        now = datetime.now()
        note = {"note_id": next(self.ids), "owner_user_id": owner_user_id, "label": label,
                "quantity": quantity, "created_at": now, "updated_at": now}
        self.lab_notes.append(note)
        return note["note_id"]

    def connect(self, **kwargs):
        if self.fail_connect is not None:
            raise self.fail_connect
        if kwargs.get("user") == INTRUDER_ACCOUNT:
            # Only this account is refused; campus_app connections are unaffected.
            self.intruder_attempts.append({k: v for k, v in kwargs.items() if k != "password"})
            if self.reject_intruder:
                raise pymysql.err.OperationalError(
                    1045, f"Access denied for user '{INTRUDER_ACCOUNT}'@'fake-client' (using password: YES)")
        conn = FakeConnection(self, kwargs)
        self.connections.append(conn)
        return conn

    def all_statements(self):
        return [s for c in self.connections for s, _ in c.statements]

    # ---------------------------------------------------------------- locks

    def lock(self, conn, key):
        with self._cond:
            while self._locks.get(key) not in (None, conn):
                if not self._cond.wait(timeout=5):
                    raise pymysql.err.OperationalError(1205, "Lock wait timeout exceeded")
            self._locks[key] = conn

    def held_locks(self):
        """{lock key: owning connection}, for tests."""
        with self._cond:
            return dict(self._locks)

    def release(self, conn):
        with self._cond:
            for key in [k for k, owner in self._locks.items() if owner is conn]:
                del self._locks[key]
            self._cond.notify_all()

    # ---------------------------------------------------------------- statements

    def _write(self, conn, text):
        self.writes.append((conn.id, conn.app_user_id, text))

    def _update(self, conn, row, **changes):
        old = {k: row[k] for k in changes}
        row.update(changes)
        conn.undo.append(lambda: row.update(old))

    def _insert(self, conn, table, row):
        table.append(row)
        conn.undo.append(lambda: table.remove(row))

    def _remove(self, conn, table, row):
        index = next(i for i, candidate in enumerate(table) if candidate is row)
        del table[index]
        conn.undo.append(lambda: table.insert(index, row))

    # ---------------------------------------------------------------- audit_lab_notes

    def _notes_of(self, owner_user_id):
        """The owner's notes, newest first (ORDER BY note_id DESC)."""
        return sorted((n for n in self.lab_notes if n["owner_user_id"] == owner_user_id),
                      key=lambda n: -n["note_id"])

    @staticmethod
    def _check_note_quantity(quantity):
        # chk_lab_notes_quantity (migration 003); PyMySQL raises OperationalError for ER 4025.
        if not 1 <= quantity <= 100:
            raise pymysql.err.OperationalError(
                4025, "CONSTRAINT `chk_lab_notes_quantity` failed for `university_resources`.`audit_lab_notes`")

    def _insert_note(self, conn, statement, owner_user_id, label, quantity, now):
        self._check_note_quantity(quantity)
        if owner_user_id not in self.users:          # fk_lab_notes_owner
            raise pymysql.err.IntegrityError(1452, "Cannot add or update a child row: fk_lab_notes_owner")
        note = {"note_id": next(self.ids), "owner_user_id": owner_user_id, "label": label,
                "quantity": quantity, "created_at": now, "updated_at": now}
        self._insert(conn, self.lab_notes, note)
        self._write(conn, statement)
        return Result(rowcount=1, lastrowid=note["note_id"])

    def _respond_lab(self, conn, s, a, now):
        """The Audit Lab's statements; None if `s` is not one of them."""
        if s == LAB_MARKER:
            return Result([(conn.id, now)])
        if s == LAB_LATEST_NOTE:
            return Result([{"note_id": n["note_id"], "label": n["label"], "quantity": n["quantity"]}
                           for n in self._notes_of(a[0])[:1]])
        if s == LAB_LIST_NOTES:
            return Result([{key: n[key] for key in ("note_id", "label", "quantity", "created_at", "updated_at")}
                           for n in self._notes_of(a[0])[:20]])
        if s == LAB_NOTE_QUANTITY:
            # As in lab.py, this statement has no owner filter: the application
            # only passes a note_id it has just read with LAB_LATEST_NOTE.
            return Result([(n["quantity"],) for n in self.lab_notes if n["note_id"] == a[0]])
        if s == LAB_INSERT:
            return self._insert_note(conn, s, a[0], a[1], a[2], now)
        if s == LAB_INSERT_INVALID:
            return self._insert_note(conn, s, a[0], a[1], 0, now)       # always fails the CHECK
        if s == LAB_UPDATE:
            self._check_note_quantity(a[0])
            rows = [n for n in self.lab_notes if n["note_id"] == a[1] and n["owner_user_id"] == a[2]]
            for n in rows:
                self.lock(conn, ("note", n["note_id"]))
                self._update(conn, n, quantity=a[0], updated_at=now)
            self._write(conn, s)
            return Result(rowcount=len(rows))
        if s in (LAB_DELETE, LAB_RESET):
            if s == LAB_DELETE:
                rows = [n for n in self.lab_notes if n["note_id"] == a[0] and n["owner_user_id"] == a[1]]
            else:
                rows = [n for n in self.lab_notes if n["owner_user_id"] == a[0]]
            for n in rows:
                self.lock(conn, ("note", n["note_id"]))
                self._remove(conn, self.lab_notes, n)
            self._write(conn, s)
            return Result(rowcount=len(rows))
        if s in (LAB_EVENTS_OF_CONNECTION, LAB_FAILED_LOGINS):
            # Records of the real plugin: the fake has none and invents none.
            if not self.plugin_installed:
                raise pymysql.err.ProgrammingError(1146, "Table 'campus_audit.plugin_events' doesn't exist")
            return Result([])
        if s == LAB_HISTORY_OF_CONNECTION:
            # Rows of the real triggers: the fake's writes never create any.
            return Result([])
        return None

    def respond(self, conn, s, a):     # noqa: C901 - one branch per known statement
        # No global mutex here: a thread waiting for a row lock must not block the
        # lock owner's next statement.  Serialization comes only from lock().
        with contextlib.nullcontext():
            if self.fail_statement:
                matcher, error = self.fail_statement
                if matcher(conn, s, a) if callable(matcher) else re.search(matcher, s):
                    self.fail_statement = None
                    raise error
            now = datetime.now()

            # ---- connection state
            if s == "SET @app_user_id = %s":
                conn.app_user_id = a[0]
                return Result()

            # ---- grant contract (database/app_account.sh)
            if re.match(r"DELETE FROM (?!audit_lab_notes\b)", s):
                raise pymysql.err.OperationalError(1142, "DELETE command denied to user 'campus_app'")
            if re.match(r"(INSERT INTO|UPDATE|DELETE FROM) (audit_events|campus_audit\.)", s):
                raise pymysql.err.OperationalError(1142, "command denied to user 'campus_app'")
            if s.startswith("INSERT INTO users") and not s.startswith(
                    "INSERT INTO users (full_name, email, password_hash) VALUES"):
                raise pymysql.err.OperationalError(1143, "INSERT command denied for column")
            if s.startswith("UPDATE users SET") and not re.match(
                    r"UPDATE users SET (full_name|password_hash) = %s WHERE user_id = %s$", s):
                raise pymysql.err.OperationalError(1143, "UPDATE command denied for column")
            if re.match(r"(INSERT INTO|UPDATE) (rooms|items)\b", s):
                raise pymysql.err.OperationalError(1142, "command denied to user 'campus_app'")

            # ---- users
            if s == "SELECT role, full_name, is_active FROM users WHERE user_id = %s":
                u = self.users.get(a[0])
                return Result([(u["role"], u["full_name"], u["is_active"])] if u else [])
            if s == "SELECT user_id, password_hash, role, full_name, is_active FROM users WHERE email = %s":
                rows = [(u["user_id"], u["password_hash"], u["role"], u["full_name"], u["is_active"])
                        for u in self.users.values() if u["email"] == a[0]]
                return Result(rows)
            if s == "SELECT full_name FROM users WHERE user_id = %s":
                u = self.users.get(a[0])
                return Result([(u["full_name"],)] if u else [])
            if s == "SELECT full_name, email FROM users WHERE user_id = %s":
                u = self.users.get(a[0])
                return Result([(u["full_name"], u["email"])] if u else [])
            if s == "SELECT password_hash FROM users WHERE user_id = %s":
                u = self.users.get(a[0])
                return Result([(u["password_hash"],)] if u else [])
            if s == "SELECT COUNT(*) FROM users":
                return Result([(len(self.users),)])
            if s.startswith("INSERT INTO users (full_name, email, password_hash) VALUES"):
                if any(u["email"] == a[1] for u in self.users.values()):
                    raise pymysql.err.IntegrityError(1062, "Duplicate entry for key 'uq_users_email'")
                user_id = next(self.ids)
                row = {"user_id": user_id, "full_name": a[0], "email": a[1], "password_hash": a[2],
                       "role": "student", "is_active": 1}          # the schema's defaults
                self.users[user_id] = row
                conn.undo.append(lambda: self.users.pop(user_id, None))
                self._write(conn, s)
                return Result(rowcount=1, lastrowid=user_id)
            m = re.match(r"UPDATE users SET (full_name|password_hash) = %s WHERE user_id = %s$", s)
            if m:
                u = self.users.get(a[1])
                if u:
                    self._update(conn, u, **{m.group(1): a[0]})
                self._write(conn, s)
                return Result(rowcount=1 if u else 0)

            # ---- housekeeping
            if s.startswith("UPDATE loans SET status = 'returned', returned_at = CURRENT_TIMESTAMP(6) "
                            "WHERE status = 'active' AND due_at <"):
                rows = [l for l in self.loans if l["status"] == "active" and l["due_at"] and l["due_at"] < now]
                for l in rows:
                    self._update(conn, l, status="returned", returned_at=now)
                self._write(conn, s)
                return Result(rowcount=len(rows))
            if s.startswith("UPDATE bookings SET status = 'completed'"):
                rows = [b for b in self.bookings if b["status"] == "confirmed" and b["end_time"] < now]
                for b in rows:
                    self._update(conn, b, status="completed")
                self._write(conn, s)
                return Result(rowcount=len(rows))

            # ---- booking transaction
            m = re.match(r"SELECT room_id, status FROM rooms WHERE name = %s ORDER BY room_id( FOR UPDATE)?$", s)
            if m:
                rows = [r for r in self.rooms if r["name"] == a[0]]
                if m.group(1):
                    for r in rows:
                        self.lock(conn, ("room", r["room_id"]))
                    if self.slow_after_lock:
                        self.slow_after_lock()
                return Result([(r["room_id"], r["status"]) for r in rows])
            m = re.match(r"SELECT item_id, status FROM items WHERE name = %s( AND asset_tag = %s)? "
                         r"ORDER BY item_id( FOR UPDATE)?$", s)
            if m:
                rows = [i for i in self.items if i["name"] == a[0] and (not m.group(1) or i["asset_tag"] == a[1])]
                if m.group(2):
                    for i in rows:
                        self.lock(conn, ("item", i["item_id"]))
                    if self.slow_after_lock:
                        self.slow_after_lock()
                return Result([(i["item_id"], i["status"]) for i in rows])
            m = re.match(r"SELECT COUNT\(\*\) FROM (bookings|loans) WHERE (room_id|item_id) IN \(([%s, ]+)\) "
                         r"AND status = '(confirmed|active)' AND (start_time|borrowed_at) < %s "
                         r"AND (end_time|due_at) > %s( FOR UPDATE)?$", s)
            if m:
                n = m.group(3).count("%s")
                ids, end, start = a[:n], a[n], a[n + 1]
                table = self.bookings if m.group(1) == "bookings" else self.loans
                key, status, lo, hi = m.group(2), m.group(4), m.group(5), m.group(6)
                count = sum(1 for r in table if r[key] in ids and r["status"] == status
                            and r[lo] < end and r[hi] > start)
                return Result([(count,)])
            if s.startswith("INSERT INTO bookings (user_id, room_id, start_time, end_time, status) VALUES"):
                row = {"booking_id": next(self.ids), "user_id": a[0], "room_id": a[1], "start_time": a[2],
                       "end_time": a[3], "status": "confirmed"}
                self._insert(conn, self.bookings, row)
                self._write(conn, s)
                return Result(rowcount=1, lastrowid=row["booking_id"])
            if s.startswith("INSERT INTO loans (user_id, item_id, borrowed_at, due_at, status) VALUES"):
                row = {"loan_id": next(self.ids), "user_id": a[0], "item_id": a[1], "borrowed_at": a[2],
                       "due_at": a[3], "returned_at": None, "status": "active"}
                self._insert(conn, self.loans, row)
                self._write(conn, s)
                return Result(rowcount=1, lastrowid=row["loan_id"])

            # ---- cancellation
            if s == ("UPDATE bookings SET status = 'cancelled' "
                     "WHERE booking_id = %s AND user_id = %s AND status = 'confirmed'"):
                rows = [b for b in self.bookings if b["booking_id"] == a[0] and b["user_id"] == a[1]
                        and b["status"] == "confirmed"]
                for b in rows:
                    self._update(conn, b, status="cancelled")
                self._write(conn, s)
                return Result(rowcount=len(rows))
            if s == ("UPDATE loans SET status = 'cancelled' WHERE loan_id = %s AND user_id = %s "
                     "AND status = 'active' AND borrowed_at > CURRENT_TIMESTAMP(6)"):
                rows = [l for l in self.loans if l["loan_id"] == a[0] and l["user_id"] == a[1]
                        and l["status"] == "active" and l["borrowed_at"] > now]
                for l in rows:
                    self._update(conn, l, status="cancelled")
                self._write(conn, s)
                return Result(rowcount=len(rows))
            if s == ("UPDATE loans SET status = 'returned', returned_at = CURRENT_TIMESTAMP(6) "
                     "WHERE loan_id = %s AND user_id = %s AND status = 'active' "
                     "AND borrowed_at <= CURRENT_TIMESTAMP(6)"):
                rows = [l for l in self.loans if l["loan_id"] == a[0] and l["user_id"] == a[1]
                        and l["status"] == "active" and l["borrowed_at"] <= now]
                for l in rows:
                    self._update(conn, l, status="returned", returned_at=now)
                self._write(conn, s)
                return Result(rowcount=len(rows))

            # ---- calendar and account pages
            if s.startswith("SELECT b.start_time, b.end_time, b.user_id, b.status, NULL AS version FROM bookings b"):
                ids = {r["room_id"] for r in self.rooms if r["name"] == a[0]}
                return Result([{"start_time": b["start_time"], "end_time": b["end_time"], "user_id": b["user_id"],
                                "status": b["status"], "version": None}
                               for b in self.bookings if b["room_id"] in ids
                               and b["status"] in ("confirmed", "completed")])
            if s.startswith("SELECT l.borrowed_at AS start_time, l.due_at AS end_time, l.user_id, l.status,"):
                items = {i["item_id"]: i for i in self.items if i["name"] == a[0]}
                return Result([{"start_time": l["borrowed_at"], "end_time": l["due_at"], "user_id": l["user_id"],
                                "status": l["status"], "version": items[l["item_id"]]["asset_tag"]}
                               for l in self.loans if l["item_id"] in items
                               and l["status"] in ("active", "returned")])
            if s.startswith("SELECT b.booking_id, r.name, r.capacity, b.start_time, b.end_time FROM bookings b"):
                rooms = {r["room_id"]: r for r in self.rooms}
                return Result([{"booking_id": b["booking_id"], "name": rooms[b["room_id"]]["name"],
                                "capacity": rooms[b["room_id"]]["capacity"], "start_time": b["start_time"],
                                "end_time": b["end_time"]}
                               for b in self.bookings if b["user_id"] == a[0] and b["status"] == "confirmed"])
            if s.startswith("SELECT l.loan_id, i.name, i.asset_tag, l.borrowed_at, l.due_at FROM loans l"):
                items = {i["item_id"]: i for i in self.items}
                return Result([{"loan_id": l["loan_id"], "name": items[l["item_id"]]["name"],
                                "asset_tag": items[l["item_id"]]["asset_tag"], "borrowed_at": l["borrowed_at"],
                                "due_at": l["due_at"]}
                               for l in self.loans if l["user_id"] == a[0] and l["status"] == "active"])

            # ---- admin page
            if "FROM audit_events ORDER BY event_id DESC LIMIT %s OFFSET %s" in s:
                if self.audit_error:
                    raise self.audit_error
                limit, offset = a
                rows = sorted(self.audit_events, key=lambda r: -r["event_id"])[offset:offset + limit]
                return Result([dict(r) for r in rows])
            if s.startswith("SHOW GLOBAL STATUS LIKE 'campus"):
                return Result([dict(r) for r in self.plugin_status] if self.plugin_installed else [])
            if s.startswith("SHOW GLOBAL VARIABLES LIKE 'campus"):
                return Result([{"Variable_name": "campus_audit_databases", "Value": "university_resources"}]
                              if self.plugin_installed else [])
            if "FROM campus_audit.v_table_activity" in s:
                if not self.plugin_installed:
                    raise pymysql.err.ProgrammingError(1146, "Table 'campus_audit.v_table_activity' doesn't exist")
                return Result([])

            # ---- Audit Lab (plugin state, notes, import)
            if s == "SELECT VERSION() AS version":
                return Result([{"version": "13.0.2-MariaDB"}])
            if "FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit'" in s:
                if not self.plugin_installed:
                    return Result([])
                return Result([{"PLUGIN_NAME": "campus_audit", "PLUGIN_VERSION": "1.1", "PLUGIN_STATUS": "ACTIVE",
                                "PLUGIN_TYPE": "AUDIT", "PLUGIN_TYPE_VERSION": "3.2",
                                "PLUGIN_LIBRARY": "campus_audit.so", "PLUGIN_AUTHOR": "x",
                                "PLUGIN_DESCRIPTION": "x", "PLUGIN_LICENSE": "GPL", "PLUGIN_MATURITY": "Beta",
                                "PLUGIN_AUTH_VERSION": "1.1"}])
            if "FROM information_schema.ROUTINES" in s:
                return Result([{"n": 1 if self.plugin_installed else 0}])
            if s == "CALL campus_audit.import_current_log()":
                if not self.plugin_installed:
                    raise pymysql.err.OperationalError(1305, "PROCEDURE campus_audit.import_current_log does not exist")
                return Result([("ok", 0, 0, 0)])
            lab_result = self._respond_lab(conn, s, a, now)
            if lab_result is not None:
                return lab_result

        raise AssertionError(f"fakedb: unexpected SQL: {s}")


# ---------------------------------------------------------------- Flask test-client helpers

def sign_in(client, user_id, role="student"):
    """A session as the app creates it after a successful login."""
    with client.session_transaction() as s:
        s["user_id"] = user_id
        s["role"] = role
        s["full_name"] = "Test"


def session_token(client):
    """The CSRF token of the client's session (created if the session has none yet)."""
    with client.session_transaction() as s:
        return s.setdefault("_csrf", secrets.token_urlsafe(24))


def form_post(client, url, data=None, **kwargs):
    """POST like a browser that loaded the form first: with the session's CSRF token."""
    data = dict(data or {})
    data["csrf_token"] = session_token(client)
    return client.post(url, data=data, **kwargs)
