-- Migration 008: import_plugin_log() leaves the caller's session as it found
-- it, also when it fails, and says what to do about a log that is too large.
--
-- Run after migration 007.  Idempotent (CREATE OR REPLACE), safe to re-run.
-- It replaces only the procedure of migration 002; the table, the views and
-- import_current_log() (migration 003, which calls this procedure) are
-- unchanged, and so are the result columns and the meaning of a re-import.
--
-- What was wrong (reproduced on 13.0.2, tests/database/test_log_import.sh):
--
-- 1. The procedure switches the session to time_zone '+00:00' (the plugin
--    writes UTC timestamps and plugin_events.event_time is a TIMESTAMP) and
--    raises max_recursive_iterations for the line splitter.  It restored both
--    only at its normal end.  When a statement in between failed -- observed
--    with a lock wait timeout on plugin_events, ER 1205 -- the CALL returned
--    the error and the session kept time_zone '+00:00', the raised iteration
--    limit and the temporary table tmp_plugin_lines.  Every later statement
--    on that connection then read and wrote TIMESTAMP values in UTC without
--    anybody having asked for it.  An exit handler now restores the two
--    settings, drops the temporary table and re-raises the original error.
--
-- 2. LOAD_FILE() cannot read a file whose size is greater than or equal to
--    the connection's max_allowed_packet.  Inside the procedure this
--    surfaced as the server's bare ER 1301 ("Result of load_file() was
--    larger than max_allowed_packet ... truncated"), which does not say that
--    the import as a whole did not happen or what to do.  The procedure reads
--    the complete file on every call (re-imports are harmless because of the
--    primary key, not because it remembers a position), so this limit is
--    reached by growth alone.  The error now names the limit and the remedy.
--
--    Measured on 13.0.2 (docs/evidence/phase1/post-audit/): the SESSION value
--    of max_allowed_packet is read-only (ER 1621); SET GLOBAL applies only to
--    connections opened afterwards; the GLOBAL value is at most 1 GiB and is
--    rounded down to a multiple of 1024.  Renaming the file does not make it
--    smaller, so rotation alone does NOT make an oversized file importable.
--    scripts/rotate_log.sh therefore checks the size of every file first and
--    imports an oversized one in line-aligned parts below the limit:
--    `make rotate-log` for the active log, `make import-log FILE=<path>`
--    (rotate_log.sh --import <path>) for a file that is already archived.
--    Raising the GLOBAL limit and calling the procedure from a NEW connection
--    also works for files below 1 GiB.
--
-- Not changed, by design: the import still reads the whole file.  A
-- position-based incremental import would need server-side state per file
-- and a way to read a byte range, which LOAD_FILE() does not offer.  Regular
-- rotation keeps each file below max_allowed_packet; a file that is already
-- too large is imported in parts by scripts/rotate_log.sh (tested by
-- tests/integration/test_log_import_limits.sh).

USE campus_audit;

DELIMITER //

CREATE OR REPLACE PROCEDURE import_plugin_log(IN log_path VARCHAR(600))
    MODIFIES SQL DATA
    COMMENT 'Import campus_audit JSON Lines; re-running only adds new records'
BEGIN
    DECLARE resolved_path VARCHAR(1200);
    DECLARE content LONGBLOB;
    DECLARE saved_time_zone VARCHAR(64) DEFAULT @@SESSION.time_zone;
    DECLARE saved_iterations BIGINT UNSIGNED DEFAULT @@SESSION.max_recursive_iterations;
    DECLARE session_changed BOOLEAN DEFAULT FALSE;
    DECLARE total_lines BIGINT UNSIGNED DEFAULT 0;
    DECLARE valid_lines BIGINT UNSIGNED DEFAULT 0;
    DECLARE imported BIGINT UNSIGNED DEFAULT 0;

    -- ER 1301: the file exists and is readable, but exceeds max_allowed_packet.
    DECLARE EXIT HANDLER FOR 1301
    BEGIN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'import_plugin_log: the file is not smaller than max_allowed_packet and was not imported; import it in parts with scripts/rotate_log.sh (make rotate-log for the active log, make import-log FILE=<path> for an archive), or SET GLOBAL max_allowed_packet above its size and call again from a new connection';
    END;
    -- Anything else that fails: give the session back as it was, then report
    -- the original error unchanged.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        IF session_changed THEN
            SET SESSION time_zone = saved_time_zone;
            SET SESSION max_recursive_iterations = saved_iterations;
        END IF;
        DROP TEMPORARY TABLE IF EXISTS tmp_plugin_lines;
        RESIGNAL;
    END;

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

    SET session_changed = TRUE;
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
