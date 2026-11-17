"""Tests of the fake database itself (tests/fakedb.py), for the Audit Lab's statements.

They pin down what the fake models, so that the route tests built on it mean
what they say: owner filters, the quantity CHECK, undo on rollback, locks
released on commit/rollback/close, @app_user_id recorded per write, the
decoy login, and loud failure on unknown SQL.  Nothing here is evidence
about MariaDB.
"""
import pymysql
import pytest

import fakedb
import lab
from fakedb import FakeDatabase


@pytest.fixture()
def db():
    return FakeDatabase()


def run(conn, sql, args=None, as_dict=False):
    cursor = conn.cursor(pymysql.cursors.DictCursor if as_dict else None)
    cursor.execute(sql, args)
    return cursor


def connection(db, user_id):
    conn = db.connect(user="campus_app")
    run(conn, "SET @app_user_id = %s", (user_id,))
    return conn


def quantities(db):
    return {n["note_id"]: n["quantity"] for n in db.lab_notes}


def test_fake_statements_are_the_labs_statements():
    """The fake matches statements literally, so they must equal lab.py's text."""
    assert fakedb.LAB_INSERT == lab.SQL["create"] and fakedb.LAB_INSERT_INVALID == lab.SQL["violate"]
    assert fakedb.LAB_UPDATE == lab.SQL["update"] == lab.SQL["rollback"]
    assert fakedb.LAB_DELETE == lab.SQL["delete"] and fakedb.LAB_RESET == lab.SQL["reset"]
    assert fakedb.LAB_PLUGIN_EVENTS == fakedb.norm(lab.EVENT_COLUMNS) + " "
    assert fakedb.LAB_HISTORY_OF_CONNECTION.startswith(fakedb.norm(lab.HISTORY_COLUMNS))
    assert fakedb.INTRUDER_ACCOUNT == lab.INTRUDER_ACCOUNT


def test_marker_is_the_connection_id(db):
    conn = connection(db, None)
    connection_id, now = run(conn, "SELECT CONNECTION_ID(), NOW(6)").fetchone()
    assert connection_id == conn.id and now is not None


def test_insert_records_owner_and_acting_user(db):
    alice = db.add_user("alice@example.edu")
    conn = connection(db, alice)
    cursor = run(conn, lab.SQL["create"], (alice, "First", 4))
    (note,) = db.lab_notes
    assert cursor.lastrowid == note["note_id"] and cursor.rowcount == 1
    assert (note["owner_user_id"], note["label"], note["quantity"]) == (alice, "First", 4)
    assert db.writes == [(conn.id, alice, lab.SQL["create"])]


def test_writes_record_the_identity_active_when_they_execute(db):
    alice = db.add_user("alice@example.edu")
    note = db.add_note(alice, quantity=1)
    conn = connection(db, alice)
    run(conn, lab.SQL["update"], (2, note, alice))
    run(conn, "SET @app_user_id = %s", (None,))
    run(conn, lab.SQL["update"], (3, note, alice))
    run(conn, "SET @app_user_id = %s", (alice,))
    run(conn, lab.SQL["update"], (4, note, alice))
    assert [user for _, user, _ in db.writes] == [alice, None, alice]


@pytest.mark.parametrize("quantity", [0, 101, -1])
def test_quantity_check_refuses_insert_and_update(db, quantity):
    alice = db.add_user("alice@example.edu")
    note = db.add_note(alice, quantity=5)
    conn = connection(db, alice)
    for sql, args in ((lab.SQL["create"], (alice, "x", quantity)), (lab.SQL["update"], (quantity, note, alice))):
        with pytest.raises(pymysql.err.OperationalError) as refused:
            run(conn, sql, args)
        assert refused.value.args[0] == 4025
    assert quantities(db) == {note: 5} and db.writes == []


def test_invalid_insert_always_fails_the_check(db):
    alice = db.add_user("alice@example.edu")
    conn = connection(db, alice)
    with pytest.raises(pymysql.err.OperationalError) as refused:
        run(conn, lab.SQL["violate"], (alice, "x"))
    assert refused.value.args[0] == 4025 and db.lab_notes == []


def test_owner_filters_of_read_update_delete_and_reset(db):
    alice, bob = db.add_user("alice@example.edu"), db.add_user("bob@example.edu")
    a1 = db.add_note(alice, "a1", 1)
    b1 = db.add_note(bob, "b1", 9)
    a2 = db.add_note(alice, "a2", 2)
    conn = connection(db, alice)
    latest, listing = fakedb.LAB_LATEST_NOTE, fakedb.LAB_LIST_NOTES
    assert run(conn, latest, (alice,), as_dict=True).fetchall() == [{"note_id": a2, "label": "a2", "quantity": 2}]
    assert run(conn, latest, (bob,), as_dict=True).fetchone()["note_id"] == b1
    assert [n["note_id"] for n in run(conn, listing, (alice,), as_dict=True).fetchall()] == [a2, a1]
    # Bob's row with Alice as owner: no row matches, nothing changes.
    assert run(conn, lab.SQL["update"], (50, b1, alice)).rowcount == 0
    assert run(conn, lab.SQL["delete"], (b1, alice)).rowcount == 0
    assert quantities(db) == {a1: 1, b1: 9, a2: 2}
    assert run(conn, lab.SQL["reset"], (alice,)).rowcount == 2
    assert quantities(db) == {b1: 9}


def test_listing_is_limited_to_twenty_rows(db):
    alice = db.add_user("alice@example.edu")
    ids = [db.add_note(alice, f"n{i}", 1) for i in range(25)]
    conn = connection(db, alice)
    listed = run(conn, fakedb.LAB_LIST_NOTES, (alice,), as_dict=True).fetchall()
    assert [n["note_id"] for n in listed] == ids[::-1][:20]


@pytest.mark.parametrize("end", ["rollback", "close"])
def test_uncommitted_changes_are_undone_and_locks_released(db, end):
    alice = db.add_user("alice@example.edu")
    kept = db.add_note(alice, "kept", 5)
    gone = db.add_note(alice, "gone", 6)
    before = [dict(n) for n in db.lab_notes]
    conn = connection(db, alice)
    run(conn, lab.SQL["update"], (99, kept, alice))
    run(conn, lab.SQL["delete"], (gone, alice))
    run(conn, lab.SQL["create"], (alice, "new", 7))
    assert quantities(db) == {kept: 99, db.lab_notes[-1]["note_id"]: 7}
    assert db.held_locks() == {("note", kept): conn, ("note", gone): conn}
    getattr(conn, end)()
    assert db.lab_notes == before                              # same rows, same order, same values
    assert db.held_locks() == {}


def test_commit_keeps_the_changes_and_releases_the_locks(db):
    alice = db.add_user("alice@example.edu")
    note = db.add_note(alice, "kept", 5)
    conn = connection(db, alice)
    run(conn, lab.SQL["update"], (8, note, alice))
    assert db.held_locks() == {("note", note): conn}
    conn.commit()
    assert db.held_locks() == {}
    conn.rollback()                                            # nothing left to undo
    assert quantities(db) == {note: 8}


def test_failed_commit_leaves_the_transaction_for_rollback(db):
    alice = db.add_user("alice@example.edu")
    note = db.add_note(alice, "kept", 5)
    conn = connection(db, alice)
    run(conn, lab.SQL["update"], (8, note, alice))
    db.fail_commit = pymysql.err.OperationalError(1213, "Deadlock found")
    with pytest.raises(pymysql.err.OperationalError):
        conn.commit()
    assert db.fail_commit is None and quantities(db) == {note: 8}
    conn.rollback()
    assert quantities(db) == {note: 5} and db.held_locks() == {}


def test_quantity_read_by_id_has_no_owner_filter_like_the_real_statement(db):
    alice, bob = db.add_user("alice@example.edu"), db.add_user("bob@example.edu")
    note = db.add_note(bob, "b", 9)
    conn = connection(db, alice)
    assert run(conn, "SELECT quantity FROM audit_lab_notes WHERE note_id = %s", (note,)).fetchone() == (9,)


def test_plugin_and_trigger_queries_return_explicitly_nothing(db):
    """The fake cannot produce these records; it returns no rows instead of inventing some."""
    alice = db.add_user("alice@example.edu")
    conn = connection(db, alice)
    run(conn, lab.SQL["create"], (alice, "First", 4))
    conn.commit()
    window = (conn.id, "2000-01-01", "2100-01-01")
    assert run(conn, fakedb.LAB_EVENTS_OF_CONNECTION, window, as_dict=True).fetchall() == []
    assert run(conn, fakedb.LAB_FAILED_LOGINS, (lab.INTRUDER_ACCOUNT,) + window[1:], as_dict=True).fetchall() == []
    assert run(conn, fakedb.LAB_HISTORY_OF_CONNECTION, window, as_dict=True).fetchall() == []
    assert db.audit_events == []
    db.plugin_installed = False
    with pytest.raises(pymysql.err.ProgrammingError):
        run(conn, fakedb.LAB_EVENTS_OF_CONNECTION, window)


def test_only_the_decoy_account_is_refused_at_login(db):
    with pytest.raises(pymysql.err.OperationalError) as refused:
        db.connect(host="h", port=3306, user=lab.INTRUDER_ACCOUNT, password="guess")
    assert refused.value.args[0] == 1045
    assert db.intruder_attempts == [{"host": "h", "port": 3306, "user": lab.INTRUDER_ACCOUNT}]   # no password kept
    assert db.connections == []
    conn = db.connect(user="campus_app", password="x")         # the application account still connects
    assert db.connections == [conn]


@pytest.mark.parametrize("sql", [
    "SELECT * FROM audit_lab_notes",
    "SELECT note_id, label, quantity FROM audit_lab_notes WHERE owner_user_id = %s",
    "UPDATE audit_lab_notes SET quantity = %s WHERE note_id = %s",          # without the owner filter
    "SELECT * FROM campus_audit.plugin_events",
    "SELECT * FROM audit_events WHERE connection_id = %s",
])
def test_unknown_sql_fails_loudly(db, sql):
    conn = connection(db, None)
    with pytest.raises(AssertionError, match="unexpected SQL"):
        run(conn, sql, (1, 2))


def test_statements_outside_the_grants_are_still_refused(db):
    conn = connection(db, None)
    for sql in ("DELETE FROM bookings WHERE booking_id = 0", "DELETE FROM audit_events",
                "UPDATE campus_audit.plugin_events SET seq = 0"):
        with pytest.raises(pymysql.err.OperationalError) as refused:
            run(conn, sql)
        assert refused.value.args[0] == 1142


def test_callable_failure_matcher_sees_connection_and_arguments(db):
    alice = db.add_user("alice@example.edu")
    conn = connection(db, alice)
    db.fail_statement = (lambda c, s, a: s == "SET @app_user_id = %s" and a == (None,),
                         pymysql.err.OperationalError(2013, "Lost connection"))
    run(conn, "SET @app_user_id = %s", (alice,))               # does not match
    with pytest.raises(pymysql.err.OperationalError):
        run(conn, "SET @app_user_id = %s", (None,))
    assert conn.app_user_id == alice and db.fail_statement is None
