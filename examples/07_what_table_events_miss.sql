-- 07  What the TABLE events do not show, and the opt-in that closes most of it.
--
-- Shows:  two limits of MariaDB's audit API that every audit plugin inherits, measured
--         on 13.0.2, and campus_audit_statement_scope = 'SESSION' (plugin 1.2.0):
--           1. under LOCK TABLES the server raises NO table event for INSERT, UPDATE
--              and DELETE (plugin_audit.h: the LOCK event "is generated once for LOCK
--              TABLES and then is suppressed until the tables are unlocked");
--           2. there is no event subclass for triggers, views or routines.  CREATE and
--              DROP TRIGGER are reported as READ access to the trigger's table.
-- Needs:  01 installed, the campus_audit schema (scripts/setup_database.sh).
--         Administrator connection (SET GLOBAL, FILE for the import).
-- Run with:  mariadb --force --table -uroot -p < examples/07_what_table_events_miss.sql
-- The same statements are checked by tests/plugin/run_plugin_tests.sh ("statements
-- without table events"); the full explanation is docs/plugin-api-notes.md, section 2a.

USE university_resources;
CREATE TABLE example07_scratch (id INT PRIMARY KEY, v INT) ENGINE=InnoDB;

-- ---------------------------------------------------------------- default scope: TABLES
SELECT @@GLOBAL.campus_audit_statement_scope AS scope;          -- TABLES

LOCK TABLES example07_scratch WRITE;                            -- one table_write + statement
INSERT INTO example07_scratch VALUES (1, 1);                    -- NOT recorded
UPDATE example07_scratch SET v = 2 WHERE id = 1;                -- NOT recorded
UNLOCK TABLES;                                                  -- NOT recorded
CREATE TRIGGER example07_trg BEFORE INSERT ON example07_scratch
    FOR EACH ROW SET NEW.v = NEW.v;                             -- NOT recorded (a "read", and reads are off)
DROP TRIGGER example07_trg;                                     -- NOT recorded

-- The rows changed all the same:
SELECT id, v FROM example07_scratch;                            -- 1, 2

-- ---------------------------------------------------------------- opt-in scope: SESSION
-- SESSION also records statements for which the server raised no table event, when the
-- session's default schema is watched or its last table access was to a watched table.
-- The plugin still does not read SQL to find out what a statement touched.
SET GLOBAL campus_audit_statement_scope = 'SESSION';

LOCK TABLES example07_scratch WRITE;                            -- table_write + statement, as before
INSERT INTO example07_scratch VALUES (2, 1);                    -- statement, "scope":"session"
UPDATE example07_scratch SET v = 3 WHERE id = 2;                -- statement, "scope":"session"
INSERT INTO example07_scratch VALUES (2, 1);                    -- [ERROR 1062] recorded with error_code 1062
UNLOCK TABLES;                                                  -- statement, "scope":"session"
START TRANSACTION;                                              -- statement, "scope":"session"
DELETE FROM example07_scratch WHERE id = 2;                     -- table_write + statement (ordinary)
ROLLBACK;                                                       -- statement, "scope":"session": the outcome is visible
CREATE PROCEDURE example07_p() SELECT 1;                        -- statement, "scope":"session"
DROP PROCEDURE example07_p;                                     -- statement, "scope":"session"

-- Trigger DDL is reported by the server as read access, so it needs log_reads as well:
SET GLOBAL campus_audit_log_reads = ON;
CREATE TRIGGER example07_trg BEFORE INSERT ON example07_scratch
    FOR EACH ROW SET NEW.v = NEW.v;                             -- table_read + statement
DROP TRIGGER example07_trg;                                     -- table_read + statement
SET GLOBAL campus_audit_log_reads = OFF;

SET GLOBAL campus_audit_statement_scope = 'TABLES';             -- back to the default

-- ---------------------------------------------------------------- what was recorded
-- Everything this connection caused, in order.  Compare the two halves: the first
-- LOCK TABLES is followed by nothing until CREATE TABLE's neighbours, the second by
-- every statement that ran under it.
CALL campus_audit.import_plugin_log(@@GLOBAL.campus_audit_file_path);
SELECT event_type,
       table_name,
       status_code AS err,
       JSON_VALUE(record, '$.scope') AS scope,
       LEFT(sql_digest, 62) AS sql_digest
  FROM campus_audit.plugin_events
 WHERE connection_id = CONNECTION_ID()
   AND instance_id = (SELECT instance_id FROM campus_audit.plugin_events ORDER BY event_time DESC, seq DESC LIMIT 1)
 ORDER BY seq;

-- Still not recorded in any configuration (docs/experiments.md, experiment 24): trigger
-- DDL with a qualified name issued from a session whose default schema is not watched
-- and whose last table access was elsewhere.  `make doctor` therefore checks that the
-- row-history triggers of database/triggers.sql all exist.

DROP TABLE example07_scratch;
