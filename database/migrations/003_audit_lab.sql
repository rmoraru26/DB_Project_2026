-- Migration 003: objects for the Audit Lab, the guided tour of the web app (/lab).
--
-- Run after migration 002.  Idempotent, safe to re-run.
--
-- 1. university_resources.audit_lab_notes: a disposable table that exists
--    only for demonstrations.  Lab actions never touch users, rooms, items,
--    bookings or loans; the app changes only rows whose owner_user_id is the
--    signed-in user.  The table lives in university_resources on purpose:
--    that is the schema the plugin watches (campus_audit_databases), and
--    triggers.sql gives it a row history like every other table, so one lab
--    action shows both mechanisms side by side.
--
-- 2. campus_audit.import_current_log(): imports the file the plugin is
--    writing right now.  import_plugin_log(path) reads the log with
--    LOAD_FILE() and therefore needs the FILE privilege.  This procedure runs
--    with its DEFINER's rights, takes no argument and can only read the path
--    in @@GLOBAL.campus_audit_file_path, so the application account is
--    granted EXECUTE on it (database/app_account.sh) instead of FILE.
--    It does not reference @@campus_audit_file_path directly: that variable
--    exists only while the plugin is installed, and the procedure must be
--    creatable before INSTALL SONAME runs.

USE university_resources;

CREATE TABLE IF NOT EXISTS audit_lab_notes (
    note_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    owner_user_id BIGINT UNSIGNED NOT NULL,
    label VARCHAR(60) NOT NULL,
    quantity SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (note_id),
    KEY idx_lab_notes_owner (owner_user_id, note_id),
    CONSTRAINT fk_lab_notes_owner
        FOREIGN KEY (owner_user_id) REFERENCES users (user_id)
        ON UPDATE RESTRICT ON DELETE CASCADE,
    -- The lab's "invalid insert" relies on this constraint: quantity 0 fails
    -- with ER 4025 after the plugin has already seen the table opened for write.
    CONSTRAINT chk_lab_notes_quantity CHECK (quantity BETWEEN 1 AND 100),
    CONSTRAINT chk_lab_notes_label_nonempty CHECK (CHAR_LENGTH(TRIM(label)) > 0)
) ENGINE=InnoDB
  COMMENT='Disposable Audit Lab rows (web app /lab); real data never lives here';

USE campus_audit;

DELIMITER //

CREATE OR REPLACE PROCEDURE import_current_log()
    SQL SECURITY DEFINER
    MODIFIES SQL DATA
    COMMENT 'Import the log campus_audit is writing now; callable without the FILE privilege'
BEGIN
    DECLARE active_log_path VARCHAR(600) DEFAULT NULL;

    SELECT VARIABLE_VALUE INTO active_log_path
      FROM information_schema.GLOBAL_VARIABLES
     WHERE VARIABLE_NAME = 'CAMPUS_AUDIT_FILE_PATH';

    IF active_log_path IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'import_current_log: the campus_audit plugin is not installed';
    END IF;

    CALL import_plugin_log(active_log_path);
END //

DELIMITER ;

-- 3. v_failed_logins (migration 002) called db_user "attempted_user" for every
--    row.  For change_user_failed that is wrong.  Observed on 13.0.2 with
--    tests/plugin/change_user.c: a CHANGE_USER event carries the security
--    context of the session BEFORE the change, both after a successful and
--    after a failed COM_CHANGE_USER, so the account in the record is the one
--    the session was logged in as; the account it tried to switch to is not
--    passed to audit plugins at all.  The view now keeps the two apart.
CREATE OR REPLACE VIEW v_failed_logins AS
SELECT event_time,
       event_type,
       CASE WHEN event_type = 'connect_failed' THEN db_user END AS attempted_user,
       CASE WHEN event_type = 'change_user_failed' THEN db_user END AS session_account_before,
       client_host,
       client_ip,
       status_code AS error_code,
       connection_id
FROM plugin_events
WHERE event_type IN ('connect_failed', 'change_user_failed');
