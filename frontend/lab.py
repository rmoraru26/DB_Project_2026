"""The Audit Lab: a guided, hands-on look at what the campus_audit plugin records.

Every lab action is one of a fixed set of statements against the disposable
table university_resources.audit_lab_notes (migration 003), executed on the
request's own connection with the application account.  Afterwards the same
connection imports the plugin's log (campus_audit.import_current_log(), a
definer procedure) and reads back

  * the plugin's records for that connection   (campus_audit.plugin_events)
  * the trigger-written row history             (university_resources.audit_events)

so the page shows what the server really recorded, never a simulation.

Why the request's own connection: every request opens a new connection, and
the plugin writes its records synchronously while the server processes each
statement, so by the time the import runs on the same connection every
record of the earlier statements is already in the file.  The connection id
(CONNECTION_ID() = the plugin's "conn") then selects exactly this action's
records.

Nothing here accepts SQL from the browser: the browser names an action from
ACTIONS, the label and quantity are validated, and every value reaches the
server through PyMySQL parameters.
"""
import json
import re
import secrets
from datetime import date, datetime, timedelta

import pymysql

ACTIONS = {
    "create": "Insert a row",
    "update": "Update your latest row",
    "delete": "Delete your latest row",
    "violate": "Insert an invalid row (CHECK violation)",
    "rollback": "Update, then ROLLBACK",
    "denied": "Run a forbidden statement",
    "failed_login": "Failed database login",
}

# The statements the lab may run, shown to the user next to the plugin's digest.
SQL = {
    "create": "INSERT INTO audit_lab_notes (owner_user_id, label, quantity) VALUES (%s, %s, %s)",
    "update": "UPDATE audit_lab_notes SET quantity = %s WHERE note_id = %s AND owner_user_id = %s",
    "delete": "DELETE FROM audit_lab_notes WHERE note_id = %s AND owner_user_id = %s",
    "violate": "INSERT INTO audit_lab_notes (owner_user_id, label, quantity) VALUES (%s, %s, 0)",
    "rollback": "UPDATE audit_lab_notes SET quantity = %s WHERE note_id = %s AND owner_user_id = %s",
    # campus_app has no DELETE privilege on bookings (database/app_account.sh), so
    # the server refuses this with ER 1142 before it opens the table.  booking 0
    # never exists, so even an over-privileged account would delete nothing.
    "denied": "DELETE FROM bookings WHERE booking_id = 0",
    "reset": "DELETE FROM audit_lab_notes WHERE owner_user_id = %s",
}

# Account used by the "failed_login" action: a locked decoy without privileges
# whose password nobody knows (database/app_account.sh), so every login fails
# with ER 1045 and the plugin records connect_failed.
INTRUDER_ACCOUNT = "audit_lab_intruder"

EVENT_TYPES = ("table_write", "table_read", "table_create", "table_alter", "table_rename",
               "table_drop", "statement", "connect", "connect_failed", "disconnect",
               "change_user", "change_user_failed", "config_change", "plugin_start",
               "plugin_stop", "audit_gap")
HISTORY_TABLES = ("users", "rooms", "items", "bookings", "loans", "audit_lab_notes")
HISTORY_ACTIONS = ("INSERT", "UPDATE", "DELETE")
SINCE_MINUTES = {"15": 15, "60": 60, "1440": 1440, "10080": 10080}
JOURNAL_SIZE = 20
EVENT_LIMIT = 200
LABEL_PATTERN = re.compile(r"^[^\x00-\x1f\x7f]{1,60}$")
NAME_PATTERN = re.compile(r"^[A-Za-z0-9_$]{1,64}$")
ACCOUNT_PATTERN = re.compile(r"^[A-Za-z0-9_.@%-]{1,80}$")


class LabError(Exception):
    """A lab request that cannot be carried out; the message is shown to the user."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


# ------------------------------------------------------------------ validation

def parse_label(value):
    label = (value or "").strip()
    if not LABEL_PATTERN.match(label):
        raise LabError("The label needs 1 to 60 characters and no control characters.")
    return label


def parse_quantity(value):
    try:
        quantity = int(value)
    except (TypeError, ValueError):
        raise LabError("The quantity must be a whole number.")
    if not 1 <= quantity <= 100:
        raise LabError("The quantity must be between 1 and 100 (the table's CHECK constraint).")
    return quantity


def parse_action(value):
    if value not in ACTIONS:
        raise LabError("Unknown lab action.")
    return value


# ------------------------------------------------------------------ serialisation

def _jsonable(value):
    if isinstance(value, (datetime, date)):
        return value.isoformat(sep=" ") if isinstance(value, datetime) else value.isoformat()
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def _row(row):
    return {key: _jsonable(value) for key, value in row.items()}


def _event(row):
    event = _row(row)
    try:
        event["record"] = json.loads(event["record"]) if event.get("record") else None
    except (TypeError, ValueError):
        event["record"] = None
    return event


def _history(row):
    entry = _row(row)
    for key in ("old_values", "new_values"):
        try:
            entry[key] = json.loads(entry[key]) if entry.get(key) else None
        except (TypeError, ValueError):
            pass
    return entry


# ------------------------------------------------------------------ plugin state

def plugin_state(db):
    """What the server reports about the plugin; readable by any account."""
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute("SELECT VERSION() AS version")
        version = cursor.fetchone()["version"]
        cursor.execute(
            "SELECT PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_TYPE_VERSION, "
            "       PLUGIN_LIBRARY, PLUGIN_AUTHOR, PLUGIN_DESCRIPTION, PLUGIN_LICENSE, PLUGIN_MATURITY, "
            "       PLUGIN_AUTH_VERSION "
            "FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit'")
        plugin = cursor.fetchone()
        cursor.execute("SHOW GLOBAL STATUS LIKE 'campus\\_audit\\_%'")
        status = {r["Variable_name"].lower(): r["Value"] for r in cursor.fetchall()}
        cursor.execute("SHOW GLOBAL VARIABLES LIKE 'campus\\_audit\\_%'")
        variables = {r["Variable_name"].lower(): r["Value"] for r in cursor.fetchall()}
        cursor.execute(
            "SELECT COUNT(*) AS n FROM information_schema.ROUTINES "
            "WHERE ROUTINE_SCHEMA = 'campus_audit' AND ROUTINE_NAME = 'import_current_log'")
        importable = cursor.fetchone()["n"] == 1
    return {
        "server_version": version,
        "plugin": _row(plugin) if plugin else None,
        "active": bool(plugin) and plugin["PLUGIN_STATUS"] == "ACTIVE",
        "status": status,
        "variables": variables,
        "import_available": importable,
    }


# ------------------------------------------------------------------ the plugin log

def import_log(db):
    """Imports the plugin's current log file; returns the procedure's summary.

    Raises LabError when the import is impossible (plugin not installed,
    migration 003 missing, file not readable); the caller decides whether the
    action itself still counts as done.
    """
    try:
        with db.cursor() as cursor:
            cursor.execute("CALL campus_audit.import_current_log()")
            row = cursor.fetchone()
            while cursor.nextset():
                pass
        db.commit()
    except pymysql.err.MySQLError as e:
        db.rollback()
        code, message = (e.args + (None, ""))[:2]
        if code == 1644:          # SIGNAL from the procedure
            raise LabError(f"Plugin log not imported: {message}", 503)
        if code in (1305, 1370):  # procedure missing / no EXECUTE privilege
            raise LabError("Plugin log not imported: the database predates migration 003 "
                           "(run make migrate, or make up).", 503)
        raise LabError(f"Plugin log not imported (MariaDB error {code}: {message}).", 503)
    if not row:
        return {"total_lines": 0, "invalid_lines_skipped": 0, "newly_imported": 0}
    return {"total_lines": row[1], "invalid_lines_skipped": row[2], "newly_imported": row[3]}


EVENT_COLUMNS = ("SELECT instance_id, seq, event_time, event_type, connection_id, query_id, db_user, "
                 "       client_host, schema_name, table_name, status_code, sql_digest, record "
                 "FROM campus_audit.plugin_events ")
HISTORY_COLUMNS = ("SELECT event_id, event_time, action, entity_table, entity_id, database_user, "
                   "       application_user_id, event_source, connection_id, old_values, new_values "
                   "FROM audit_events ")


def _window(started):
    return started - timedelta(seconds=2), started + timedelta(minutes=10)


def events_of_connection(db, connection_id, started):
    low, high = _window(started)
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute(EVENT_COLUMNS + "WHERE connection_id = %s AND event_time BETWEEN %s AND %s "
                       "ORDER BY instance_id, seq", (connection_id, low, high))
        return [_event(r) for r in cursor.fetchall()]


def failed_logins_since(db, account, started):
    low, high = _window(started)
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute(EVENT_COLUMNS + "WHERE event_type = 'connect_failed' AND db_user = %s "
                       "AND event_time BETWEEN %s AND %s ORDER BY instance_id, seq",
                       (account, low, high))
        return [_event(r) for r in cursor.fetchall()]


def history_of_connection(db, connection_id, started):
    low, high = _window(started)
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute(HISTORY_COLUMNS + "WHERE connection_id = %s AND event_time BETWEEN %s AND %s "
                       "ORDER BY event_id", (connection_id, low, high))
        return [_history(r) for r in cursor.fetchall()]


# ------------------------------------------------------------------ lab rows

def notes_of(db, user_id):
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute("SELECT note_id, label, quantity, created_at, updated_at FROM audit_lab_notes "
                       "WHERE owner_user_id = %s ORDER BY note_id DESC LIMIT 20", (user_id,))
        return [_row(r) for r in cursor.fetchall()]


def _latest_note(db, user_id):
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute("SELECT note_id, label, quantity FROM audit_lab_notes WHERE owner_user_id = %s "
                       "ORDER BY note_id DESC LIMIT 1", (user_id,))
        note = cursor.fetchone()
    if note is None:
        raise LabError("You have no lab row yet: insert one first.", 409)
    return note


def _marker(db):
    """CONNECTION_ID() and the server's NOW(6) of the request's connection."""
    with db.cursor() as cursor:
        cursor.execute("SELECT CONNECTION_ID(), NOW(6)")
        return cursor.fetchone()


# ------------------------------------------------------------------ actions

def perform(db, user_id, action, label, quantity, db_config):
    """Runs one allow-listed action and returns everything the page shows about it."""
    connection_id, started = _marker(db)
    outcome = {"ok": True, "error_code": None, "message": ""}
    statement = SQL.get(action)
    note = None

    if action == "create":
        with db.cursor() as cursor:
            cursor.execute(SQL["create"], (user_id, label, quantity))
            note_id = cursor.lastrowid
        db.commit()
        outcome["message"] = f"Inserted lab row #{note_id}."
    elif action == "update":
        note = _latest_note(db, user_id)
        with db.cursor() as cursor:
            cursor.execute(SQL["update"], (quantity, note["note_id"], user_id))
        db.commit()
        outcome["message"] = f"Row #{note['note_id']}: quantity {note['quantity']} -> {quantity}."
    elif action == "delete":
        note = _latest_note(db, user_id)
        with db.cursor() as cursor:
            cursor.execute(SQL["delete"], (note["note_id"], user_id))
        db.commit()
        outcome["message"] = f"Deleted lab row #{note['note_id']}."
    elif action == "violate":
        try:
            with db.cursor() as cursor:
                cursor.execute(SQL["violate"], (user_id, label))
            db.commit()
            outcome = {"ok": True, "error_code": None,
                       "message": "Unexpected: the server accepted quantity 0 (is migration 003 applied?)"}
        except pymysql.err.MySQLError as e:
            db.rollback()
            outcome = {"ok": False, "error_code": e.args[0],
                       "message": f"MariaDB refused the statement: ERROR {e.args[0]}: {e.args[1]}"}
    elif action == "rollback":
        note = _latest_note(db, user_id)
        with db.cursor() as cursor:
            cursor.execute(SQL["rollback"], (quantity, note["note_id"], user_id))
            changed = cursor.rowcount
        db.rollback()
        with db.cursor() as cursor:
            cursor.execute("SELECT quantity FROM audit_lab_notes WHERE note_id = %s", (note["note_id"],))
            after = cursor.fetchone()[0]
        outcome["message"] = (f"The UPDATE succeeded ({changed} row) and was rolled back: "
                              f"row #{note['note_id']} still has quantity {after}.")
    elif action == "denied":
        try:
            with db.cursor() as cursor:
                cursor.execute(SQL["denied"])
            db.commit()
            outcome = {"ok": True, "error_code": None,
                       "message": "Unexpected: the application account may DELETE bookings."}
        except pymysql.err.MySQLError as e:
            db.rollback()
            outcome = {"ok": False, "error_code": e.args[0],
                       "message": f"MariaDB refused the statement: ERROR {e.args[0]}: {e.args[1]}"}
    elif action == "failed_login":
        statement = None
        try:
            probe = pymysql.connect(host=db_config["DB_HOST"], port=db_config["DB_PORT"],
                                    user=INTRUDER_ACCOUNT, password=secrets.token_urlsafe(18),
                                    connect_timeout=5)
            probe.close()
            outcome = {"ok": True, "error_code": None,
                       "message": f"Unexpected: the server accepted a login as {INTRUDER_ACCOUNT}."}
        except pymysql.err.MySQLError as e:
            outcome = {"ok": False, "error_code": e.args[0],
                       "message": f"MariaDB refused the login of '{INTRUDER_ACCOUNT}': ERROR {e.args[0]}"}
    else:
        raise LabError("Unknown lab action.")

    result = {
        "action": action,
        "title": ACTIONS[action],
        "connection_id": connection_id,
        "started_at": _jsonable(started),
        "statement": statement,
        "outcome": outcome,
        "plugin": {"imported": False, "import": None, "error": None, "events": []},
        "history": [],
    }
    try:
        result["plugin"]["import"] = import_log(db)
        result["plugin"]["imported"] = True
    except LabError as e:
        result["plugin"]["error"] = str(e)
    if result["plugin"]["imported"]:
        if action == "failed_login":
            result["plugin"]["events"] = failed_logins_since(db, INTRUDER_ACCOUNT, started)
        else:
            result["plugin"]["events"] = events_of_connection(db, connection_id, started)
    result["history"] = history_of_connection(db, connection_id, started)
    result["notes"] = notes_of(db, user_id)
    return result


def reset(db, user_id):
    with db.cursor() as cursor:
        cursor.execute(SQL["reset"], (user_id,))
        removed = cursor.rowcount
    db.commit()
    return removed


# ------------------------------------------------------------------ explorer

def journal_entry(result):
    """(connection id, start time) pairs that let a student see their own records."""
    entries = []
    if result["action"] == "failed_login":
        for event in result["plugin"]["events"]:
            entries.append([event["connection_id"], result["started_at"]])
    else:
        entries.append([result["connection_id"], result["started_at"]])
    return entries


def _since_clause(args, column, clauses, params):
    since = args.get("since", "60")
    if since in SINCE_MINUTES:
        clauses.append(f"{column} >= NOW(6) - INTERVAL %s MINUTE")
        params.append(SINCE_MINUTES[since])
    elif since not in ("", "all"):
        raise LabError("Unknown time range.")


def explore_events(db, args, journal=None):
    """Plugin records, newest first.  journal=None means every record (administrators)."""
    clauses, params = [], []
    if journal is not None:
        if not journal:
            return []
        scope = []
        for connection_id, started in journal[-JOURNAL_SIZE:]:
            low, high = _window(datetime.fromisoformat(started))
            scope.append("(connection_id = %s AND event_time BETWEEN %s AND %s)")
            params.extend([int(connection_id), low, high])
        clauses.append("(" + " OR ".join(scope) + ")")
    event_type = args.get("type", "")
    if event_type:
        if event_type not in EVENT_TYPES:
            raise LabError("Unknown event type.")
        clauses.append("event_type = %s")
        params.append(event_type)
    table = args.get("table", "")
    if table:
        if not NAME_PATTERN.match(table):
            raise LabError("Table names contain only letters, digits, _ and $.")
        clauses.append("table_name = %s")
        params.append(table)
    account = args.get("account", "")
    if account:
        if not ACCOUNT_PATTERN.match(account):
            raise LabError("Unsupported characters in the account filter.")
        clauses.append("db_user LIKE %s")
        params.append(account.replace("%", "").replace("_", "\\_") + "%")   # prefix match
    outcome = args.get("outcome", "")
    if outcome == "error":
        clauses.append("((event_type = 'statement' AND status_code <> 0) OR event_type IN "
                       "('connect_failed', 'change_user_failed', 'audit_gap'))")
    elif outcome == "ok":
        clauses.append("event_type = 'statement' AND status_code = 0")
    elif outcome:
        raise LabError("Unknown outcome filter.")
    _since_clause(args, "event_time", clauses, params)
    where = ("WHERE " + " AND ".join(clauses) + " ") if clauses else ""
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute(EVENT_COLUMNS + where + "ORDER BY event_time DESC, seq DESC LIMIT %s",
                       params + [EVENT_LIMIT])
        return [_event(r) for r in cursor.fetchall()]


def explore_history(db, args, user_id=None):
    """Trigger-written row history, newest first.  user_id=None means all rows (administrators)."""
    clauses, params = [], []
    if user_id is not None:
        clauses.append("application_user_id = %s")
        params.append(user_id)
    table = args.get("table", "")
    if table:
        if table not in HISTORY_TABLES:
            raise LabError("Unknown table.")
        clauses.append("entity_table = %s")
        params.append(table)
    action = args.get("action", "")
    if action:
        if action not in HISTORY_ACTIONS:
            raise LabError("Unknown row action.")
        clauses.append("action = %s")
        params.append(action)
    _since_clause(args, "event_time", clauses, params)
    where = ("WHERE " + " AND ".join(clauses) + " ") if clauses else ""
    with db.cursor(pymysql.cursors.DictCursor) as cursor:
        cursor.execute(HISTORY_COLUMNS + where + "ORDER BY event_id DESC LIMIT %s", params + [EVENT_LIMIT])
        return [_history(r) for r in cursor.fetchall()]
