-- Migration 006: a 'cancelled' status for loans that never started.
--
-- Run after migration 005 (scripts/setup_database.sh and the Docker initdb
-- order apply it after seed.sql).  Idempotent, safe to re-run.
--
-- Why: the application account campus_app has no DELETE privilege on loans
-- (database/app_account.sh); real tables keep their history.  The official
-- web app cancels a scheduled future loan by deleting the unstarted row.  That
-- will be changed (in a later stage, not by this migration) into
--
--     UPDATE loans SET status = 'cancelled'
--      WHERE loan_id = ? AND user_id = ? AND status = 'active'
--        AND borrowed_at > CURRENT_TIMESTAMP(6);
--
-- which campus_app may run with its existing UPDATE privilege and which the
-- loans UPDATE trigger records in audit_events like every other change.
--
-- What changes: 'cancelled' is appended to the loans.status ENUM.  The
-- existing values keep their order and stored index, the default stays
-- 'active', and no row is deleted or updated (appending an ENUM value is a
-- metadata-only change in MariaDB).  The CHECK constraint
-- chk_loans_status_returned_consistent is unchanged: it already requires
-- returned_at IS NULL for every status other than 'returned', which is exactly
-- the rule for a cancelled loan.
--
-- Safety: the column type is altered only when it is exactly the official
-- enum('active','returned','lost').  If 'cancelled' is already present the
-- migration does nothing; any other definition stops the migration with an
-- error instead of risking a reinterpretation of stored values.

USE university_resources;

DELIMITER //

BEGIN NOT ATOMIC
    DECLARE v_status_type LONGTEXT DEFAULT NULL;

    SET v_status_type = (
        SELECT COLUMN_TYPE
          FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE()
           AND TABLE_NAME = 'loans'
           AND COLUMN_NAME = 'status');

    IF v_status_type IS NULL
       OR v_status_type NOT IN ('enum(''active'',''returned'',''lost'')',
                                'enum(''active'',''returned'',''lost'',''cancelled'')') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'migration 006: loans.status is not the expected enum(active,returned,lost); not altered';
    END IF;

    IF v_status_type = 'enum(''active'',''returned'',''lost'')' THEN
        ALTER TABLE loans
            MODIFY status ENUM('active', 'returned', 'lost', 'cancelled')
                NOT NULL DEFAULT 'active'
                COMMENT 'cancelled = a scheduled loan withdrawn before borrowed_at (migration 006)';
    END IF;
END //

DELIMITER ;
