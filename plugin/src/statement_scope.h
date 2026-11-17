// Which statements get a "statement" record, decided from audit API facts only.
//
// The TABLE class is how campus_audit learns that a statement belongs to a
// watched schema, and it has blind spots:
//
//   * LOCK TABLES.  The installed header (mysql/plugin_audit.h, 0x0303) says
//     of the LOCK event: "This event is generated at the beginning of every
//     statement for every affected table, unless there's a LOCK TABLES
//     statement in effect (in which case it is generated once for LOCK TABLES
//     and then is suppressed until the tables are unlocked)."  INSERT, UPDATE
//     and DELETE under LOCK TABLES therefore raise no table event at all.
//   * Its subclasses are LOCK, CREATE, DROP, RENAME and ALTER of a *table*;
//     there is none for triggers, views or routines.  Observed on 13.0.2:
//     DROP VIEW raises no table event; CREATE/DROP PROCEDURE raise one for
//     mysql.proc only; CREATE/DROP TRIGGER and CREATE VIEW raise a LOCK event
//     with read_only = 1 for the table they refer to, i.e. the server reports
//     them like a SELECT (they are recorded when campus_audit_log_reads is ON).
//   * COMMIT, ROLLBACK and SET touch no table.
//
// A GENERAL STATUS event still arrives for every such statement, but it names
// no table and carries no SQL command type, only the session's default schema.
// The plugin does not parse SQL text to guess what a statement touched.
// Instead the opt-in scope SESSION records the statements the TABLE class
// could not classify, by two rules that use nothing but event facts:
//
//   (a) the session's default schema is a watched schema, or
//   (b) the last statement of this connection that raised table events
//       touched a watched table (the "latch").  LOCK TABLES on a watched table
//       is such a statement, so everything executed under that lock is
//       recorded whatever the default schema is.
//
// Both rules apply only to
//   * statements that raised NO table event.  A statement whose table events
//     were all for other schemas, or reads while campus_audit_log_reads is
//     OFF, stays unrecorded as before.  Events for the server's own schemas
//     (mysql, information_schema, performance_schema, sys) are not counted:
//     the caller does not report them to note_table_event();
//   * the protocol commands that run SQL (Query, Execute), not Quit or Ping;
//   * statements that are not part of another statement.  The body of a
//     trigger gets a STATUS event of its own, with its own query id, BEFORE
//     the STATUS event of the statement that fired it, while that statement's
//     table events are still waiting for their statement record (observed on
//     13.0.2).  Such a statement is not something the client sent; its table
//     access is already recorded with the outer statement.
//
// No server header is needed here, so the logic is unit-tested without
// MariaDB (tests/test_statement_scope.cpp).
#ifndef CAMPUS_AUDIT_STATEMENT_SCOPE_H
#define CAMPUS_AUDIT_STATEMENT_SCOPE_H

#include <cstring>

namespace campus_audit {

// Values of the system variable campus_audit_statement_scope.
enum StatementScope {
    kScopeTables = 0,   // statements with a recorded table event, and refused ones (default)
    kScopeSession = 1   // additionally: statements without table events, rules (a) and (b)
};

// Per-connection bookkeeping, updated on every TABLE event of the connection
// (also events for user schemas that are not watched; not for system schemas).
struct TableEventTrack {
    unsigned long long seen_query_id;      // statement that raised the latest table event
    unsigned long long recorded_query_id;  // statement whose watched table events wait for their STATUS event
    unsigned long long latched;            // 1 while rule (b) holds
};

// Called for each TABLE event.  `recorded` says whether this event was for a
// watched schema and was written (not filtered by user or by log_reads).
inline void note_table_event(TableEventTrack* track, unsigned long long query_id, bool recorded) {
    if (track->seen_query_id != query_id) {
        // First table event of a new statement: it decides the latch afresh.
        track->seen_query_id = query_id;
        track->latched = 0;
    }
    if (recorded) {
        track->recorded_query_id = query_id;
        track->latched = 1;
    }
}

// general_command of the two protocol commands that execute an SQL statement:
// COM_QUERY ("Query") and COM_STMT_EXECUTE ("Execute").  Quit, Ping, Init DB,
// Prepare, Close stmt and the others are not statements.
inline bool is_sql_command(const char* command, unsigned int length) {
    if (command == nullptr) return false;
    return (length == 5 && std::memcmp(command, "Query", 5) == 0) ||
           (length == 7 && std::memcmp(command, "Execute", 7) == 0);
}

struct StatementFacts {
    bool config_change;            // this statement was an accepted SET GLOBAL campus_audit_*
    bool recorded_table_event;     // a watched table event of this statement was written
    bool any_table_event;          // the server raised a table event for this statement
    bool open_recorded_statement;  // another statement's recorded table events still wait for its STATUS event
    bool sql_command;              // is_sql_command(general_command)
    bool latched;                  // rule (b) holds for the connection
    bool default_schema_watched;   // rule (a)
    bool access_denied;            // the error code is a privilege refusal
    unsigned long scope;           // StatementScope
};

struct StatementDecision {
    bool record;
    bool apply_user_filter;        // campus_audit_exclude_users decides for this record
    bool mark_access_denied;       // field "access_denied": true
    bool mark_session;             // field "scope": "session"
};

inline StatementDecision decide_statement(const StatementFacts& f) {
    StatementDecision d = {false, false, false, false};
    if (f.config_change || f.recorded_table_event) {
        // Unchanged since 1.0: the table events of this statement were
        // written (their own filters applied), or the plugin's configuration
        // changed.  The statement record closes them.
        d.record = true;
        return d;
    }
    // Since 1.1.0: a statement the privilege system refused before any table
    // was opened, in a session whose default schema is watched.
    const bool refused = f.access_denied && f.default_schema_watched;
    // Since 1.2.0, scope SESSION: a statement the TABLE class could not see.
    const bool unclassified = f.sql_command && !f.any_table_event && !f.open_recorded_statement;
    const bool session = f.scope == kScopeSession && unclassified &&
                         (f.latched || f.default_schema_watched);
    if (!refused && !session) return d;
    d.record = true;
    d.apply_user_filter = true;
    d.mark_access_denied = f.access_denied;
    d.mark_session = session;
    return d;
}

}  // namespace campus_audit

#endif
