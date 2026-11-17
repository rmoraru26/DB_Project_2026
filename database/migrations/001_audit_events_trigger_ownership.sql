-- Migration 001: make audit_events the row-level history written by SQL triggers.
--
-- Run after schema.sql.  Idempotent (IF NOT EXISTS), safe to re-run.
--
-- Why: the campus_audit server plugin receives statement- and table-level
-- audit events; the MariaDB audit API does not pass row images (no old/new
-- column values) to plugins.  Row-level before/after values can only come
-- from triggers, so audit_events is owned by the triggers in triggers.sql and
-- the plugin writes to its own JSON Lines file, imported into the separate
-- campus_audit schema (migration 002).  Nothing else should insert here.
--
-- connection_id stores CONNECTION_ID(), which equals the "conn" field of the
-- plugin's records; it is the join key between the two mechanisms.

USE university_resources;

ALTER TABLE audit_events
    ADD COLUMN IF NOT EXISTS connection_id BIGINT UNSIGNED NULL
        COMMENT 'CONNECTION_ID() of the session; equals campus_audit "conn"'
        AFTER client_host,
    ADD KEY IF NOT EXISTS idx_audit_connection (connection_id, event_time),
    COMMENT = 'Row-level change history. Written only by the triggers in database/triggers.sql';

ALTER TABLE audit_events
    MODIFY database_user VARCHAR(288) NULL
        COMMENT 'USER() of the session (login user@host), not the trigger definer',
    MODIFY application_user_id BIGINT UNSIGNED NULL
        COMMENT 'Value of @app_user_id asserted by the application; NULL if unset or unknown',
    MODIFY event_source ENUM('application', 'direct_sql', 'unknown')
        NOT NULL DEFAULT 'unknown'
        COMMENT 'application when the session set @app_user_id, otherwise direct_sql';
