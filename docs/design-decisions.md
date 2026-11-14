# Design decisions

## 1. Plugin type: audit plugin

Area 11 allows an audit plugin, an INFORMATION_SCHEMA table or an aggregate function.  The resource
system's open problem was "who changed bookings, loans and resources, and with what result", so an
audit plugin is the natural fit.  An INFORMATION_SCHEMA plugin would need the private server headers
(`TABLE`, `Field`) and a matching server build; the audit API is a small, stable C interface
(`plugin_audit.h`, interface 0x0303) that works with the headers every MariaDB package installs.

## 2. Event classes: TABLE + GENERAL STATUS + CONNECTION, filtered by schema

The goal is one clearly defined class of events the way a university IT team would want it:
**all write access and DDL on the resource schema, each with the outcome of its statement, plus
failed logins**.

- **TABLE LOCK** gives exactly the tables a statement opens, with the schema, so the plugin can filter
  by schema without parsing SQL.  Reads are optional (`campus_audit_log_reads`), because they
  dominate volume.
- **GENERAL STATUS** gives the error code and the statement text once per statement; on its own it
  does not say which tables were touched.  The plugin joins the two through `query_id` and a hidden
  per-connection variable, and only writes a statement record for statements that touched a watched
  table.  GENERAL LOG/ERROR/RESULT/WARNING would only duplicate this.
- **CONNECTION** records failed logins by default (`FAILED`); `ALL` adds connect/disconnect.

## 3. What the plugin does *not* claim: row images

No audit event carries column values.  The plugin therefore records *which table* a statement opened
for writing, *who* ran it, and *whether it succeeded* – never *what changed in a row*.  Row-level
before/after values come from AFTER triggers (`database/triggers.sql`) that write
`university_resources.audit_events`.

| | SQL triggers → `audit_events` | campus_audit plugin → JSONL → `campus_audit.plugin_events` |
|---|---|---|
| Answers | what changed in which row (old/new JSON) | who opened which table with which statement, and the result |
| Sees failed statements | no (rolled back with the statement) | yes, with the error code |
| Sees DDL, failed logins | no | yes |
| Sees rolled-back transactions | no (the history row is rolled back too) | yes (it records the statement, not the commit) |
| Application identity | `@app_user_id` set by the app (NULL for housekeeping and anonymous requests, section 4) | no (only the database account) |
| Failure behaviour | **fail-closed**: if the history insert fails, the user's statement fails | **fail-open**: the statement succeeds, the gap is counted and announced |
| Can be bypassed by | a client with ALTER/DROP TRIGGER or SUPER | an admin with SUPER (UNINSTALL / SET GLOBAL) – but config changes and plugin_stop are logged |

Ownership is unambiguous: only the triggers write `audit_events`; only `import_plugin_log()` writes
`campus_audit.plugin_events`.  The application account cannot write either (tested:
`test_application_account_cannot_delete_or_forge_history`).  The join between them is
`audit_events.connection_id = plugin conn`, plus table and time (`v_row_change_history`), because
triggers cannot read the query id.

`database/triggers.sql` is the only trigger set.  The team's earlier `database/sql/audit_triggers.sql`
created `trg_bookings_a{i,u,d}_audit` and `trg_loans_a{i,u,d}_audit`; `CREATE OR REPLACE TRIGGER`
does not remove triggers with other names and MariaDB allows several triggers per table and event,
so on a database that had the old set both would fire and every booking or loan change would be
recorded twice.  `database/triggers.sql` therefore drops those six triggers before creating its
own, the old file is marked superseded, and `tests/database/test_audit_triggers.sh` checks that each
audited table has exactly one AFTER trigger per event and that one change yields one history row.

## 4. Identity

- `user`/`priv_user` in plugin records and `database_user` (`USER()`) in trigger rows are the
  **database account** (`campus_app` for everything the web app does).
- `application_user_id` is the **student/admin** the web app authenticated; it is written by the app
  as `SET @app_user_id` on every request connection.  It is an assertion by the client: any session
  can set it, which is why it is labelled "asserted" and why `event_source` only says whether it was
  set.  A non-existent id is stored as NULL, not invented.
- `CURRENT_USER()` would be wrong inside a trigger (it is the trigger's DEFINER).

### What `event_source` means, and what it does not

Every trigger in `database/triggers.sql` computes the column from one fact:
`IF(@app_user_id IS NULL, 'direct_sql', 'application')`.

| Value | Written when | It does **not** mean |
|---|---|---|
| `application` | the session had a non-NULL `@app_user_id` when the row changed | that the id is genuine (it is asserted) or exists: an id without a `users` row gives `application_user_id` NULL with `event_source = application` |
| `direct_sql` | `@app_user_id` was NULL: no application user was asserted for this change | that the statement came from outside the web application |
| `unknown` | never by the current triggers; it is the column default in `database/schema.sql` and migration 001 | – |

So `direct_sql` reads "no application user is named as the actor", not "someone typed SQL". Three
kinds of write get it:

1. **Housekeeping by the web app.** `expire_finished_reservations()` in `frontend/app.py` runs when a
   signed-in user opens an item or room booking page or their bookings page. It marks *every* user's
   overdue loans `returned` and past bookings `completed`. The user who loaded the page is only the
   occasion for these updates, not their author, and most of the rows belong to other people;
   recording the visitor's id would state that this person changed someone else's reservation. The
   function therefore sets `@app_user_id` to NULL, runs the two UPDATEs, commits, and restores the
   visitor's id for the rest of the request (if it cannot restore it, the connection is closed and the
   request fails). The history rows of the cleanup have `application_user_id = NULL`,
   `event_source = direct_sql` and `database_user = campus_app@<host>`.
2. **Anonymous requests of the web app.** Registration inserts the new `users` row before anybody is
   signed in, so `@app_user_id` is NULL: same three values.
3. **Statements outside the web app**: the setup scripts, `frontend/seed.py`, a `mariadb` client.
   Here `database_user` is the account that was used (not `campus_app`, unless somebody logged in
   with its password).

The authenticated visitor and the recorded actor are therefore two different things. The session
cookie decides who may load a page; `application_user_id` says on whose behalf a row was changed, and
it is NULL whenever the application cannot honestly name one person. To tell the three cases apart,
read `database_user` and the changed columns (the cleanup only ever sets `status` and `returned_at`),
or join `connection_id` to the plugin records, which contain the statement itself
(`v_row_change_history`).

This is a known limitation of the two-valued derivation, kept on purpose: the triggers and the ENUM
are unchanged, there is no separate value for application housekeeping, and no placeholder "system"
user id is written, because `application_user_id` references `users` and a sentinel row would be an
invented person. Consequences for a reader of the history: the administrator's change-history page
shows these rows with application user "unknown" and source `direct_sql`; a filter on one
`application_user_id` does not return the automatic completion of that user's bookings; and counting
`direct_sql` rows overstates manual database access. The fake-database tests
(`test_housekeeping_is_not_attributed_to_the_visiting_student` and the following ones in
`frontend/tests/test_app.py`) check that the cleanup runs with `@app_user_id` NULL and that the
visitor's id is back for the next write; the stored `direct_sql` value follows from the trigger text
and can only be observed against MariaDB.

## 5. Output: JSON Lines file, imported on demand

Writing to a table from inside an audit callback is not part of the API and would re-enter the
storage layer while the server holds the statement's table locks.  A file is what the built-in
server_audit plugin also uses.  JSON Lines keeps every record self-describing (missing data is
`null`, never invented), can be read by `jq` or any language, and is imported with plain SQL
(`LOAD_FILE` + `JSON_VALUE`).  The import is idempotent (`INSERT IGNORE` on `(instance_id, seq)`),
skips torn or invalid lines and reports how many it skipped.

The price of `LOAD_FILE` showed up only on Linux: it reads nothing but files that are readable by all
(`S_IROTH`), and the plugin keeps its log closed to other users.  The first Docker CI runs therefore
imported nothing at all.  Rather than open every log by default, plugin 1.1.1 has a startup option,
`campus_audit_readable_by_all`, which the Docker image turns on together with a `0750 mysql:mysql`
log directory (see `docs/security.md`).  An import that does not need `LOAD_FILE` (an
INFORMATION_SCHEMA table provided by the plugin, or reading the file outside the server) would remove
the trade-off; it is listed as future work (README section 7).

## 6. Data minimisation

The plugin never writes raw SQL.  `sql_digest()` replaces every literal (strings, numbers,
hex/bit literals, `_charset'...'`), removes all comments (including `/*! ... */`) and collapses
whitespace.  Passwords in `CREATE USER ... IDENTIFIED BY '...'`, password hashes in
`UPDATE users SET password_hash = '...'` and the personal data that PyMySQL interpolates into the
statements of the web app are all literals and therefore never reach the log.  Statement records
exist only for watched schemas, so administrative statements elsewhere are not logged at all.
See `docs/security.md`.

Where the lexer cannot know the rule, it masks more rather than less.  Double-quoted text is masked
although it is an identifier under ANSI_QUOTES.  And a backslash before a quote, which ends a literal
under NO_BACKSLASH_ESCAPES but not by default, turns the rest of the statement into one literal:
`UPDATE t SET note = 'it\'s mine' WHERE id = 5` is recorded as `UPDATE t SET note = ?`.  The digest
loses some structure in that rare case; a literal never leaks in either mode.

## 7. Error policy

| Situation | Behaviour |
|---|---|
| Invalid configuration at INSTALL / server start | `init` fails, reason as warning + error log, plugin inactive, server keeps running |
| Invalid `SET GLOBAL` (path, lists, enum) | rejected with ER 1231; reason in `SHOW WARNINGS`; previous value stays |
| New log file cannot be opened | `SET GLOBAL` rejected; old file stays active |
| Write fails at runtime | fail-open: statement unaffected; state `DEGRADED`; one error-log line per outage; retry every 5 s; `audit_gap` record with the number of lost records on recovery |
| Record would not fit its buffer / allocation fails | record dropped and counted in `Campus_audit_events_dropped`; it does not increment the I/O-only gap count or produce a recovery marker |
| Unexpected event class or subclass, NULL event | ignored and counted (`Campus_audit_events_unexpected`) |
| Exception inside a callback | caught at the C boundary; record dropped and counted |
| Non-UTF-8 bytes, control characters, quotes in names or SQL | escaped; invalid UTF-8 replaced by U+FFFD |
| deinit after a failed init | ignored (guarded) |

Fail-open is not a choice here – the audit API cannot fail a statement – but the design makes the
loss *visible* (counter, state, error log, `audit_gap`).  Sites that need fail-closed auditing must
use triggers (as for row history) or stop the service when `Campus_audit_state` is not `ACTIVE`.

## 8. Builds

- Linux: compiled inside the pinned official image against the headers of exactly that server
  version (`libmariadbd-dev=$MARIADB_VERSION`).
- Windows: Zig as a self-contained compiler (no Visual Studio needed), against the headers shipped in
  every MariaDB Windows installation.  An MSVC build is possible (MariaDB's own CMake `MYSQL_ADD_PLUGIN`
  in a server source tree) but was not attempted; there is no MSVC on the machine we tested on.
- Maturity BETA rather than STABLE: the plugin is a student project with the test coverage listed in
  `docs/testing.md`; claiming "stable" to avoid one configuration line would be misleading.

## 9. Reuse of the team's existing code

`AuditResult`/`AuditError` (`plugin/audit_error.h`) is the result type of every fallible plugin
operation; `report_audit_error()` routes failures to the right sink (server error service outside
callbacks, stderr inside callbacks); `validate_log_path()` was added next to the original
`try_open_log()` in `audit_file_check.cpp` and is used by the log sink.  The original tests still
build and pass.

## 10. Refused statements are recorded (plugin 1.1.0)

Testing the web app's least-privilege account showed that a `DELETE` the server refuses (ER 1142) left
no trace: the privilege check comes before the table is opened, so no TABLE event fires, and 1.0.0
wrote statement records only for statements that had opened a watched table (experiment 14).  For an
audit trail of a resource system, refused write attempts are exactly what an administrator wants to
see, and the project claimed to record failed statements.  1.1.0 therefore also writes the statement
record when GENERAL STATUS carries a privilege error (1044, 1142, 1143, 1227, 1370), marked
`"access_denied": true`.  A GENERAL event names no tables, so "watched" is decided by the session's
default schema; a refused statement that names a watched table from another default schema stays
invisible.  That limit is tested and documented rather than guessed around by parsing SQL.  The
exclusion list applies to these records too, using the account name at the start of the event's
account string (`priv_user[user] @ host [ip]`, built by `make_user_name()` in the server's
`sql/sql_audit.h`).  For ordinary accounts that is the login name TABLE records are filtered by; for
anonymous and proxy logins it is not, and such a refused statement is recorded even if the login is
excluded, which errs on the side of the audit log.

## 11. The Audit Lab: a guided tour that only shows real records

The web app has a guided tour at `/lab` so that a newcomer can see the plugin work without reading C++
or SQL first.  Decisions:

- **Real records only.** Every number and record on the page comes from the server: plugin state from
  `information_schema.PLUGINS` and `SHOW GLOBAL STATUS/VARIABLES`, plugin records from
  `campus_audit.plugin_events` after an import, row history from `audit_events`.  The illustrative
  diagram is the only static content.
- **No SQL from the browser.** The browser names one of seven actions; each maps to one fixed,
  parameterised statement in `frontend/lab.py`.  This avoids the weakness of an endpoint that executes
  caller-supplied SQL, even behind allow-lists.
- **A disposable table in the watched schema.** `audit_lab_notes` (migration 003) lives in
  `university_resources`, so the plugin watches it and the same kind of trigger records its history,
  but the lab never touches bookings, loans or users.  Each user changes only their own rows.
- **Import without FILE.** `import_current_log()` is a definer procedure without arguments; the
  application account may execute it, but cannot choose the file and has no FILE privilege.
- **Correlation by connection.** Every request opens its own connection, and the import runs on that
  same connection after the action.  The server writes the GENERAL STATUS record before it reads the
  connection's next command, so all records of the action are in the file, and `connection_id`
  selects exactly them.  The time window (two seconds before to ten minutes after the action) keeps a
  connection id reused after a server restart from matching.
- **A decoy account for the failed login.** Logging in as a non-existent account with PyMySQL does not give
  ER 1045 on 13.0.2 (experiment 16), and failing logins with the app's own account could lock it when
  `max_password_errors` is set.  `audit_lab_intruder` is locked, has no privileges and an unknown
  password.
- **Students see their own records.** The connection ids of a user's lab actions are kept in the
  signed session; only administrators can list every record.
