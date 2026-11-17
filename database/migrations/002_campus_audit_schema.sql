-- Migration 002: the campus_audit schema for records written by the
-- campus_audit server plugin.
--
-- The plugin itself writes JSON Lines to a file (writing to tables from inside
-- an audit callback is not supported by the audit API and would re-enter the
-- server while it holds table locks).  An administrator imports the file with
--
--     CALL campus_audit.import_plugin_log(@@GLOBAL.campus_audit_file_path);
--
-- The schema is deliberately separate from university_resources so that the
-- import itself is not audited by the plugin (its default watch list is
-- university_resources only) and so that application accounts get no write
-- access: database/app_account.sh grants campus_app SELECT here and, since
-- migration 003, EXECUTE on import_current_log() only (never FILE).
-- Idempotent; requires MariaDB 10.6+ (JSON_VALUE, recursive CTEs).

CREATE DATABASE IF NOT EXISTS campus_audit
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE campus_audit;

CREATE TABLE IF NOT EXISTS plugin_events (
    instance_id VARCHAR(48) NOT NULL
        COMMENT 'Plugin load instance ("instance"); seq restarts with each instance',
    seq BIGINT UNSIGNED NOT NULL,
    event_time TIMESTAMP(6) NOT NULL COMMENT 'Plugin clock, stored from UTC',
    event_type VARCHAR(32) NOT NULL,
    connection_id BIGINT UNSIGNED NULL COMMENT 'Server thread id = CONNECTION_ID()',
    query_id BIGINT UNSIGNED NULL,
    db_user VARCHAR(384) NULL COMMENT 'Login user (table/connection events) or account string (statement)',
    client_host VARCHAR(255) NULL,
    client_ip VARCHAR(64) NULL,
    schema_name VARCHAR(64) NULL,
    table_name VARCHAR(64) NULL,
    status_code INT NULL COMMENT 'error_code of statements, status of connection events',
    sql_digest TEXT NULL COMMENT 'Statement text with all literals replaced by ?',
    record JSON NOT NULL COMMENT 'The complete original JSON record',
    imported_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (instance_id, seq),
    KEY idx_plugin_events_time (event_time),
    KEY idx_plugin_events_stmt (connection_id, query_id),
    KEY idx_plugin_events_table (schema_name, table_name, event_time),
    KEY idx_plugin_events_type (event_type, event_time)
) ENGINE=InnoDB
  COMMENT='Imported campus_audit plugin records. Written only by import_plugin_log()';

DELIMITER //

CREATE OR REPLACE PROCEDURE import_plugin_log(IN log_path VARCHAR(600))
    MODIFIES SQL DATA
    COMMENT 'Import campus_audit JSON Lines; re-running only adds new records'
BEGIN
    DECLARE resolved_path VARCHAR(1200);
    DECLARE content LONGBLOB;
    DECLARE saved_time_zone VARCHAR(64) DEFAULT @@SESSION.time_zone;
    DECLARE saved_iterations BIGINT UNSIGNED DEFAULT @@SESSION.max_recursive_iterations;
    DECLARE total_lines BIGINT UNSIGNED DEFAULT 0;
    DECLARE valid_lines BIGINT UNSIGNED DEFAULT 0;
    DECLARE imported BIGINT UNSIGNED DEFAULT 0;

    IF log_path IS NULL OR log_path = '' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'import_plugin_log: the log path is empty';
    END IF;

    -- The plugin resolves relative paths against the data directory.
    SET resolved_path = IF(log_path LIKE '/%'
                           OR log_path REGEXP '^[A-Za-z]:[/\\\\]'
                           OR log_path LIKE '\\\\\\\\%',
                           log_path, CONCAT(@@GLOBAL.datadir, log_path));
    SET content = LOAD_FILE(resolved_path);
    IF content IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'import_plugin_log: LOAD_FILE returned NULL (file missing, not readable by all, no FILE privilege, outside secure_file_priv, or larger than max_allowed_packet)';
    END IF;

    SET SESSION time_zone = '+00:00';
    SET SESSION max_recursive_iterations = 100000000;

    CREATE OR REPLACE TEMPORARY TABLE tmp_plugin_lines (line LONGTEXT NOT NULL);

    -- Split on '\n'.  LOAD_FILE returns a binary string, so LOCATE works on
    -- byte offsets.  An unterminated last line (a record still being
    -- written) is skipped and picked up by the next import.
    INSERT INTO tmp_plugin_lines (line)
    WITH RECURSIVE bounds (start_pos, end_pos) AS (
        SELECT 1, LOCATE(0x0A, content, 1)
        UNION ALL
        SELECT end_pos + 1, LOCATE(0x0A, content, end_pos + 1)
        FROM bounds
        WHERE end_pos > 0
    )
    SELECT CONVERT(SUBSTRING(content, start_pos, end_pos - start_pos) USING utf8mb4)
    FROM bounds
    WHERE end_pos > start_pos;

    SELECT COUNT(*), COALESCE(SUM(JSON_VALID(line)), 0)
      INTO total_lines, valid_lines
      FROM tmp_plugin_lines;

    INSERT IGNORE INTO plugin_events
        (instance_id, seq, event_time, event_type, connection_id, query_id,
         db_user, client_host, client_ip, schema_name, table_name,
         status_code, sql_digest, record)
    SELECT JSON_VALUE(line, '$.instance'),
           JSON_VALUE(line, '$.seq'),
           STR_TO_DATE(JSON_VALUE(line, '$.ts'), '%Y-%m-%dT%H:%i:%s.%fZ'),
           JSON_VALUE(line, '$.event'),
           JSON_VALUE(line, '$.conn'),
           JSON_VALUE(line, '$.query_id'),
           COALESCE(JSON_VALUE(line, '$.user'), JSON_VALUE(line, '$.account')),
           JSON_VALUE(line, '$.host'),
           JSON_VALUE(line, '$.ip'),
           JSON_VALUE(line, '$.db'),
           JSON_VALUE(line, '$.table'),
           CASE WHEN JSON_VALUE(line, '$.event') = 'statement'
                THEN JSON_VALUE(line, '$.error_code')
                ELSE JSON_VALUE(line, '$.status') END,
           JSON_VALUE(line, '$.sql_digest'),
           line
    FROM tmp_plugin_lines
    WHERE JSON_VALID(line)
      AND JSON_VALUE(line, '$.instance') IS NOT NULL
      AND JSON_VALUE(line, '$.seq') IS NOT NULL;
    SET imported = ROW_COUNT();

    DROP TEMPORARY TABLE tmp_plugin_lines;
    SET SESSION time_zone = saved_time_zone;
    SET SESSION max_recursive_iterations = saved_iterations;

    SELECT resolved_path AS log_file,
           total_lines,
           total_lines - valid_lines AS invalid_lines_skipped,
           imported AS newly_imported;
END //

DELIMITER ;

-- Table access per statement, joined with the statement outcome.
CREATE OR REPLACE VIEW v_table_activity AS
SELECT t.event_time,
       t.event_type,
       t.schema_name,
       t.table_name,
       t.db_user,
       t.client_host,
       t.connection_id,
       t.query_id,
       s.status_code AS statement_error_code,
       s.sql_digest,
       t.instance_id
FROM plugin_events AS t
LEFT JOIN plugin_events AS s
       ON s.instance_id = t.instance_id
      AND s.connection_id = t.connection_id
      AND s.query_id = t.query_id
      AND s.event_type = 'statement'
WHERE t.event_type IN ('table_read', 'table_write', 'table_create',
                       'table_drop', 'table_rename', 'table_alter');

CREATE OR REPLACE VIEW v_failed_logins AS
SELECT event_time, event_type, db_user AS attempted_user, client_host, client_ip,
       status_code AS error_code, connection_id
FROM plugin_events
WHERE event_type IN ('connect_failed', 'change_user_failed');

-- Plugin lifecycle, configuration changes and announced data loss.
CREATE OR REPLACE VIEW v_plugin_lifecycle AS
SELECT event_time, event_type, instance_id, seq,
       JSON_VALUE(record, '$.variable') AS variable,
       JSON_VALUE(record, '$.value') AS value,
       JSON_VALUE(record, '$.dropped_events') AS dropped_events,
       JSON_VALUE(record, '$.last_error') AS last_error
FROM plugin_events
WHERE event_type IN ('plugin_start', 'plugin_stop', 'config_change', 'audit_gap');

-- Best-effort link between a trigger-written row change and the plugin's view
-- of the statement that caused it.  Triggers cannot read the query id, so the
-- match uses the connection id, the table name and time: CURRENT_TIMESTAMP(6)
-- in a trigger is the statement *start* time, which precedes the plugin's
-- table-lock event of the same statement.  The 60-second window keeps reused
-- connection ids (they restart after a server restart) from matching.
CREATE OR REPLACE VIEW v_row_changes_with_statement AS
SELECT ae.event_id,
       ae.event_time AS row_change_time,
       ae.action,
       ae.entity_table,
       ae.entity_id,
       ae.database_user,
       ae.application_user_id,
       ae.event_source,
       ae.connection_id,
       (SELECT MIN(t.query_id)
          FROM plugin_events AS t
         WHERE t.event_type = 'table_write'
           AND t.connection_id = ae.connection_id
           AND t.schema_name = 'university_resources'
           AND t.table_name = ae.entity_table
           AND t.event_time >= ae.event_time
           AND t.event_time < ae.event_time + INTERVAL 60 SECOND) AS plugin_query_id
FROM university_resources.audit_events AS ae;

-- Row change + who/what statement, as far as the two sources can be joined.
CREATE OR REPLACE VIEW v_row_change_history AS
SELECT r.*,
       s.db_user AS plugin_account,
       s.status_code AS statement_error_code,
       s.sql_digest
FROM v_row_changes_with_statement AS r
LEFT JOIN plugin_events AS s
       ON s.event_type = 'statement'
      AND s.connection_id = r.connection_id
      AND s.query_id = r.plugin_query_id
      AND s.event_time >= r.row_change_time
      AND s.event_time < r.row_change_time + INTERVAL 60 SECOND;
