-- 03  Read what the plugin recorded: raw JSON Lines, then SQL views.
--
-- Shows:  the plugin's log is a file; campus_audit.import_plugin_log() loads it into
--         a table so that audit records can be joined with the trigger-based row
--         history.  (Why a file: see docs/design-decisions.md.)
-- Needs:  02 done.  The FILE privilege and a log inside secure_file_priv (the
--         Docker image and README Quick start A configure this).
-- Real output of these statements: docs/evidence/demo-windows.txt, steps 3-8.

-- The raw records, newest at the end.  Look for:
--   "event":"table_write"    schema, table, account, host, connection id, query id
--   "event":"statement"      error_code, status, sql_digest with every literal as ?
--   "event":"connect_failed" attempted user, host, error code
SELECT RIGHT(LOAD_FILE(@@GLOBAL.campus_audit_file_path), 2500) AS tail_of_log\G

-- Import the file.  Safe to repeat: lines already imported are skipped
-- (the result shows total_lines, invalid_lines_skipped, newly_imported).
CALL campus_audit.import_plugin_log(@@GLOBAL.campus_audit_file_path);

-- Table access together with the OUTCOME of the statement that caused it.
-- err = 0 means the statement succeeded; 4025 is the rejected INSERT of example 02.
SELECT event_time, event_type, table_name, db_user, connection_id, query_id,
       statement_error_code AS err, LEFT(sql_digest, 70) AS sql_digest
  FROM campus_audit.v_table_activity
 ORDER BY event_time DESC LIMIT 6;

-- Row changes written by the TRIGGERS (who/what/which row), joined with the plugin's
-- statement through connection id and time.  The join is best effort, see
-- docs/design-decisions.md: a trigger cannot read the plugin's query id.
SELECT event_id, entity_table, action, entity_id, application_user_id AS app_user,
       event_source, plugin_query_id, LEFT(sql_digest, 60) AS sql_digest
  FROM campus_audit.v_row_change_history
 ORDER BY event_id DESC LIMIT 3;

-- Failed logins (needs campus_audit_connections = FAILED, the default, or ALL).
SELECT event_time, attempted_user, client_host, error_code
  FROM campus_audit.v_failed_logins
 ORDER BY event_time DESC LIMIT 3;

-- Is the plugin healthy?  ACTIVE, and events_dropped = 0 means nothing was lost.
SHOW GLOBAL STATUS LIKE 'Campus\_audit\_%';
