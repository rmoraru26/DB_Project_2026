// Unit tests for src/statement_scope.h: which statements get a record, and the
// per-connection bookkeeping behind campus_audit_statement_scope=SESSION.
// No MariaDB needed.  The sequences below are the ones observed on 13.0.2
// (docs/experiments.md); the comments name the SQL that produces them.
#include "../src/statement_scope.h"

#include <cstdio>

using campus_audit::StatementDecision;
using campus_audit::StatementFacts;
using campus_audit::TableEventTrack;
using campus_audit::decide_statement;
using campus_audit::is_sql_command;
using campus_audit::kScopeSession;
using campus_audit::kScopeTables;
using campus_audit::note_table_event;

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const char* label) {
    ++checks;
    if (condition) {
        std::printf("PASS: %s\n", label);
    } else {
        ++failures;
        std::printf("FAIL: %s\n", label);
    }
}

// An ordinary SQL statement (COM_QUERY) with no other fact set.
StatementFacts facts(unsigned long scope) {
    StatementFacts f = {};
    f.scope = scope;
    f.sql_command = true;
    return f;
}

bool same(const StatementDecision& d, bool record, bool filter, bool denied, bool session) {
    return d.record == record && d.apply_user_filter == filter && d.mark_access_denied == denied &&
           d.mark_session == session;
}

// One connection as the plugin sees it: table events, then STATUS events.
// It keeps the bookkeeping exactly as on_table() and on_general() do.
struct Connection {
    TableEventTrack track;
    unsigned long scope;
    bool default_schema_watched;
    unsigned long long next_query_id;

    Connection(unsigned long s, bool watched_default)
        : track(), scope(s), default_schema_watched(watched_default), next_query_id(100) {}

    // Table events of one statement.  'W' recorded watched event, 'o' event
    // that was not recorded (other schema, filtered user, read with log_reads
    // OFF), 's' event for a system schema such as mysql.proc, which the
    // plugin does not report to note_table_event().
    unsigned long long events(const char* list) {
        const unsigned long long query_id = next_query_id++;
        for (const char* e = list; *e; ++e) {
            if (*e != 's') note_table_event(&track, query_id, *e == 'W');
        }
        return query_id;
    }

    // The GENERAL STATUS event of statement `query_id`.
    StatementDecision status(unsigned long long query_id, bool access_denied = false, bool sql_command = true) {
        StatementFacts f = facts(scope);
        f.sql_command = sql_command;
        f.recorded_table_event = track.recorded_query_id != 0 && track.recorded_query_id == query_id;
        f.open_recorded_statement = !f.recorded_table_event && track.recorded_query_id != 0;
        f.any_table_event = track.seen_query_id != 0 && track.seen_query_id == query_id;
        f.latched = track.latched != 0;
        f.default_schema_watched = default_schema_watched;
        f.access_denied = access_denied;
        if (f.recorded_table_event) track.recorded_query_id = 0;      // as on_general does
        return decide_statement(f);
    }

    // An ordinary statement: its table events, then its STATUS event.
    StatementDecision statement(const char* list, bool access_denied = false) {
        return status(events(list), access_denied);
    }
};

}  // namespace

int main() {
    // ---------------------------------------------------------------- decide_statement
    {
        StatementFacts f = facts(kScopeTables);
        check(same(decide_statement(f), false, false, false, false),
              "TABLES: a statement without any fact is not recorded");
        f.recorded_table_event = true;
        check(same(decide_statement(f), true, false, false, false),
              "a statement with a recorded table event is recorded without extra marks");
        f = facts(kScopeTables);
        f.config_change = true;
        check(same(decide_statement(f), true, false, false, false),
              "an accepted SET GLOBAL campus_audit_* is recorded");
        f = facts(kScopeSession);
        f.recorded_table_event = true;
        f.latched = true;
        f.default_schema_watched = true;
        check(same(decide_statement(f), true, false, false, false),
              "SESSION: a statement with a recorded table event is not marked scope=session");
    }
    {
        StatementFacts f = facts(kScopeTables);
        f.access_denied = true;
        check(!decide_statement(f).record, "TABLES: a refusal outside a watched default schema is not recorded");
        f.default_schema_watched = true;
        check(same(decide_statement(f), true, true, true, false),
              "TABLES: a refusal in a watched default schema is recorded with access_denied (since 1.1.0)");
        f.sql_command = false;
        f.open_recorded_statement = true;
        check(same(decide_statement(f), true, true, true, false),
              "TABLES: the 1.1.0 refusal rule does not depend on the two SESSION conditions");
        f = facts(kScopeTables);
        f.default_schema_watched = true;
        check(!decide_statement(f).record,
              "TABLES: a table-less statement in a watched default schema is NOT recorded (default behaviour)");
        f.latched = true;
        check(!decide_statement(f).record, "TABLES: the latch alone records nothing");
    }
    {
        StatementFacts f = facts(kScopeSession);
        check(!decide_statement(f).record,
              "SESSION: a table-less statement with neither rule (a) nor (b) is not recorded");
        f.default_schema_watched = true;
        check(same(decide_statement(f), true, true, false, true),
              "SESSION rule (a): table-less statement in a watched default schema is recorded, scope=session");
        f.default_schema_watched = false;
        f.latched = true;
        check(same(decide_statement(f), true, true, false, true),
              "SESSION rule (b): table-less statement after a watched table access is recorded, scope=session");
        f.any_table_event = true;
        check(!decide_statement(f).record,
              "SESSION: a statement that raised table events, none recorded, is not recorded (it was classified)");
        f.default_schema_watched = true;
        check(!decide_statement(f).record,
              "SESSION: the same holds in a watched default schema (reads with log_reads OFF stay unrecorded)");
        f.access_denied = true;
        check(same(decide_statement(f), true, true, true, false),
              "SESSION: a refusal that raised table events is recorded by the 1.1.0 rule only");
        f.any_table_event = false;
        check(same(decide_statement(f), true, true, true, true),
              "SESSION: a table-less refusal carries both marks");
        f.default_schema_watched = false;
        check(same(decide_statement(f), true, true, true, true),
              "SESSION rule (b): a refusal under the latch is recorded although the default schema is not watched");
    }
    {
        StatementFacts f = facts(kScopeSession);
        f.default_schema_watched = true;
        f.latched = true;
        f.sql_command = false;
        check(!decide_statement(f).record, "SESSION: a protocol command that is not a statement (Quit, Ping) is not recorded");
        f.sql_command = true;
        f.open_recorded_statement = true;
        check(!decide_statement(f).record,
              "SESSION: a statement executed inside a statement whose table events are recorded (trigger body) is not recorded");
        f.open_recorded_statement = false;
        check(decide_statement(f).record, "SESSION: with both conditions met the statement is recorded");
    }

    // ---------------------------------------------------------------- is_sql_command
    check(is_sql_command("Query", 5) && is_sql_command("Execute", 7), "Query and Execute are SQL commands");
    check(!is_sql_command("Quit", 4) && !is_sql_command("Ping", 4) && !is_sql_command("Init DB", 7) &&
          !is_sql_command("Prepare", 7) && !is_sql_command("Close stmt", 10) && !is_sql_command("Change user", 11),
          "Quit, Ping, Init DB, Prepare, Close stmt and Change user are not");
    check(!is_sql_command("Query", 4) && !is_sql_command("Queryx", 6) && !is_sql_command("query", 5) &&
          !is_sql_command("", 0) && !is_sql_command(nullptr, 5),
          "the command name must match exactly; NULL and empty names are not SQL commands");

    // ---------------------------------------------------------------- note_table_event
    {
        TableEventTrack t = TableEventTrack();
        note_table_event(&t, 7, false);
        check(t.seen_query_id == 7 && t.recorded_query_id == 0 && t.latched == 0,
              "an unrecorded table event marks the statement as seen, not as recorded");
        note_table_event(&t, 7, true);
        check(t.seen_query_id == 7 && t.recorded_query_id == 7 && t.latched == 1,
              "a recorded event of the same statement sets the latch");
        note_table_event(&t, 7, false);
        check(t.latched == 1 && t.recorded_query_id == 7,
              "a later unrecorded event of the SAME statement does not clear the latch (multi-table statement)");
        note_table_event(&t, 8, false);
        check(t.seen_query_id == 8 && t.latched == 0 && t.recorded_query_id == 7,
              "the first event of a NEW statement clears the latch; the recorded id is left for its STATUS event");
        note_table_event(&t, 8, true);
        check(t.latched == 1 && t.recorded_query_id == 8, "and a recorded event sets it again");
    }

    // ---------------------------------------------------------------- sequences seen on 13.0.2
    {
        // USE other; LOCK TABLES watched.t WRITE; INSERT; UPDATE; DELETE; UNLOCK TABLES; SELECT other.x
        Connection c(kScopeSession, false);
        check(same(c.statement("W"), true, false, false, false), "LOCK TABLES on a watched table: one table event, recorded");
        check(same(c.statement(""), true, true, false, true), "INSERT under LOCK TABLES (no table event): recorded, scope=session");
        check(same(c.statement(""), true, true, false, true), "UPDATE under LOCK TABLES: recorded");
        check(same(c.statement(""), true, true, false, true), "a failing statement under LOCK TABLES: recorded");
        check(same(c.statement(""), true, true, false, true), "UNLOCK TABLES: recorded (the end of the locked section is visible)");
        check(!c.statement("o").record, "the next statement on another schema is not recorded");
        check(!c.statement("").record, "and ends rule (b): a following table-less statement is not recorded");
    }
    {
        // The same sequence with the default scope: only LOCK TABLES itself is recorded (the 1.1.1 behaviour).
        Connection c(kScopeTables, false);
        check(c.statement("W").record, "TABLES: LOCK TABLES on a watched table is recorded");
        check(!c.statement("").record && !c.statement("").record && !c.statement("").record,
              "TABLES: DML under LOCK TABLES is not recorded (documented limit of the default scope)");
    }
    {
        // USE watched; DROP VIEW v; COMMIT; SELECT ...; INSERT ...
        Connection c(kScopeSession, true);
        check(same(c.statement(""), true, true, false, true), "rule (a): DROP VIEW in a watched default schema is recorded");
        check(same(c.statement(""), true, true, false, true), "rule (a): COMMIT in a watched default schema is recorded");
        check(!c.statement("o").record, "rule (a): SELECT with log_reads OFF raises an unrecorded table event and stays unrecorded");
        check(same(c.statement("W"), true, false, false, false), "rule (a): an ordinary INSERT is recorded as before, unmarked");
    }
    {
        // USE other; INSERT INTO watched.t; COMMIT; SELECT FROM other.x; COMMIT
        Connection c(kScopeSession, false);
        check(c.statement("W").record, "INSERT into a watched table from another default schema is recorded");
        check(same(c.statement(""), true, true, false, true), "rule (b): the COMMIT that follows it is recorded");
        check(!c.statement("o").record, "a statement on other tables is not recorded");
        check(!c.statement("").record, "and the COMMIT after that one is not recorded");
    }
    {
        // Multi-table statement: other.a first, watched.t second; then COMMIT.
        Connection c(kScopeSession, false);
        check(c.statement("oW").record, "a statement that touches another schema and a watched table is recorded");
        check(c.statement("").record, "rule (b) holds after it");
        check(c.statement("Wo").record && c.statement("").record, "the order of its table events does not matter");
    }
    {
        // USE watched; INSERT INTO t ...  with an AFTER INSERT trigger that writes watched.h.
        // Events: t and h under the INSERT's query id; then STATUS of the trigger's
        // body statement (its own query id); then STATUS of the INSERT.
        Connection c(kScopeSession, true);
        const unsigned long long outer = c.events("WW");
        const unsigned long long body = c.next_query_id++;
        check(!c.status(body).record,
              "a trigger's body statement, whose STATUS event arrives while the firing statement is open, is not recorded");
        check(same(c.status(outer), true, false, false, false), "the firing statement is recorded once, unmarked");
        check(same(c.statement(""), true, true, false, true), "the COMMIT after it is recorded: nothing is left open");
        Connection d(kScopeTables, true);
        const unsigned long long outer2 = d.events("WW");
        const unsigned long long body2 = d.next_query_id++;
        check(!d.status(body2).record && d.status(outer2).record, "TABLES: the same sequence gives exactly the firing statement");
    }
    {
        // USE watched; CALL p()  where p does: INSERT INTO t (watched); SELECT ... FROM other.o
        // The INSERT is a statement of its own (events and STATUS under its own id); CALL has no table event.
        Connection c(kScopeSession, true);
        const unsigned long long call = c.next_query_id++;
        check(same(c.statement("W"), true, false, false, false), "a routine's INSERT into a watched table is recorded as its own statement");
        check(!c.statement("o").record, "a routine's SELECT from another schema is not recorded");
        check(same(c.status(call), true, true, false, true), "the CALL itself raised no table event and is recorded, scope=session");
    }
    {
        // USE watched; ...; the client disconnects: STATUS for the Quit command.
        Connection c(kScopeSession, true);
        check(c.statement("W").record, "a statement on a watched table");
        check(!c.status(c.next_query_id++, false, false).record, "the Quit command that ends the connection is not recorded as a statement");
    }
    {
        // USE watched; CREATE PROCEDURE p() ...   (the only table event is for mysql.proc)
        Connection c(kScopeSession, true);
        check(same(c.statement("s"), true, true, false, true),
              "rule (a): CREATE PROCEDURE, whose only table event is for mysql.proc, is recorded");
        check(!c.statement("so").record, "a statement that also touched another user schema is classified and not recorded");
        Connection d(kScopeTables, true);
        check(!d.statement("s").record, "TABLES: CREATE PROCEDURE is not recorded (default behaviour)");
        // USE other; INSERT watched.t; GRANT ... (grant tables only)
        Connection e(kScopeSession, false);
        check(e.statement("W").record && same(e.statement("s"), true, true, false, true),
              "rule (b): a system-schema event does not clear the latch");
    }
    {
        // USE watched; CREATE TRIGGER trg ... ON t   (log_reads OFF: the read event on t is not recorded)
        Connection c(kScopeSession, true);
        check(!c.statement("o").record,
              "documented limit: CREATE TRIGGER is reported as a read of its table and is not recorded while log_reads is OFF");
    }
    {
        // USE other; DROP TRIGGER watched.trg  -- neither rule applies: stays invisible (documented).
        Connection c(kScopeSession, false);
        check(!c.statement("").record,
              "documented limit: table-less DDL with a qualified name from another default schema, no latch, is not recorded");
    }

    std::printf("Checks: %d, Failures: %d\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
