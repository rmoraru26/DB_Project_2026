-- 04  Configure the plugin at run time, and see how it refuses bad input.
--
-- Shows:  dynamic system variables with validation, filtering, and the rule that a
--         rejected value never replaces a working one.
-- Needs:  01 installed.  Administrator connection.
-- Run with:  mariadb --force -uroot -p < examples/04_configure_and_break_it.sql
-- The expected error of every statement marked [ERROR] is taken from
-- tests/plugin/run_plugin_tests.sh (executed against MariaDB 13.0.2, Windows).

-- ---------------------------------------------------------------- filtering
-- Which schemas are audited?  Default: university_resources.  '*' means every schema
-- except mysql, information_schema, performance_schema and sys.
SELECT @@GLOBAL.campus_audit_databases;

-- Read access is off by default (volume!).  Turn it on, read, turn it off again.
SET GLOBAL campus_audit_log_reads = ON;
SELECT COUNT(*) FROM university_resources.rooms;        -- now recorded as table_read
SET GLOBAL campus_audit_log_reads = OFF;

-- Record every connection, successful or not (default is FAILED, NONE switches off).
SET GLOBAL campus_audit_connections = 'ALL';
SET GLOBAL campus_audit_connections = 'FAILED';

-- Digest length 0 records no SQL text at all (the strictest privacy setting).
SET GLOBAL campus_audit_max_sql_length = 0;
SET GLOBAL campus_audit_max_sql_length = 1024;

-- ---------------------------------------------------------------- invalid input
-- Every statement below fails with ERROR 1231 and a reason in SHOW WARNINGS.
-- The previous value stays in force; the plugin never ends up half configured.
SET GLOBAL campus_audit_databases = 'bad name';           -- [ERROR 1231] space
SET GLOBAL campus_audit_databases = 'a,,b';               -- [ERROR 1231] empty element
SET GLOBAL campus_audit_databases = '*,a';                -- [ERROR 1231] '*' with names
SET GLOBAL campus_audit_exclude_users = 'x;DROP';         -- [ERROR 1231] punctuation
SET GLOBAL campus_audit_connections = 'SOMETIMES';        -- [ERROR 1231] not NONE/FAILED/ALL
SET GLOBAL campus_audit_file_path = '';                   -- [ERROR 1231] empty path
SET GLOBAL campus_audit_file_path = NULL;                 -- [ERROR 1231] NULL path
SET GLOBAL campus_audit_file_path = 'no_such_directory/x.jsonl';  -- [ERROR 1231] cannot be opened
SHOW WARNINGS;      -- "Cannot open audit log '...': No such file or directory (errno 2)"

-- Still the value from before the failed statements:
SELECT @@GLOBAL.campus_audit_databases, @@GLOBAL.campus_audit_file_path;

-- ---------------------------------------------------------------- log rotation
-- A new path is opened first and only then replaces the old one.  To make the plugin
-- reopen the current path after an external tool renamed the file:
SET GLOBAL campus_audit_reopen_now = ON;                  -- reads back OFF; recorded as
                                                          -- a config_change record
-- Every SET GLOBAL on a campus_audit_ variable is itself audited (event config_change),
-- attributed to the account that issued it.
SHOW GLOBAL STATUS LIKE 'Campus\_audit\_%';
