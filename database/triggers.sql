-- Row-level change history for university_resources (SQL triggers).
--
-- Run after schema.sql and migrations 001-003 (it needs audit_events.connection_id
-- and audit_lab_notes), before seed.sql.  Re-runnable (DROP IF EXISTS,
-- CREATE OR REPLACE).  scripts/setup_database.sh and the Docker initdb order
-- apply it in that position.
--
-- This file is the only trigger set for the audited tables.  It replaces the
-- team's earlier database/sql/audit_triggers.sql, whose six triggers have
-- other names (trg_<table>_a{i,u,d}_audit).  CREATE OR REPLACE does not
-- remove differently named triggers, and MariaDB allows several triggers per
-- table and event, so both sets would fire and every booking or loan change
-- would be recorded twice.  The legacy triggers are therefore dropped first.
--
-- Responsibilities (see docs/design-decisions.md):
--   * these triggers own university_resources.audit_events and record WHAT
--     changed in a row (old/new column values as JSON);
--   * the campus_audit server plugin records WHO touched WHICH table with
--     WHICH statement and whether it succeeded, including failed statements
--     and DDL, which triggers never see.
--
-- Identity columns:
--   database_user        USER(): the login of the session.  CURRENT_USER()
--                        would return the trigger DEFINER inside a trigger.
--   application_user_id  @app_user_id, set by the web application after it
--                        authenticated the student/admin.  It is an assertion
--                        by the client, not something the server verified;
--                        an id that does not exist in users is stored as NULL.
--   event_source         'application' if @app_user_id is set, else 'direct_sql'.
--
-- users.password_hash is deliberately never copied into the history.
-- AFTER triggers run inside the statement: if writing the history row fails,
-- the user's statement fails too (fail-closed), unlike the plugin (fail-open).

USE university_resources;

-- Legacy trigger set of database/sql/audit_triggers.sql (superseded).
DROP TRIGGER IF EXISTS trg_bookings_ai_audit;
DROP TRIGGER IF EXISTS trg_bookings_au_audit;
DROP TRIGGER IF EXISTS trg_bookings_ad_audit;
DROP TRIGGER IF EXISTS trg_loans_ai_audit;
DROP TRIGGER IF EXISTS trg_loans_au_audit;
DROP TRIGGER IF EXISTS trg_loans_ad_audit;

CREATE OR REPLACE TRIGGER trg_users_audit_insert
AFTER INSERT ON users
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('INSERT', 'users', CAST(NEW.user_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     NULL,
     JSON_OBJECT('user_id', NEW.user_id, 'full_name', NEW.full_name, 'email', NEW.email, 'role', NEW.role, 'is_active', NEW.is_active),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_users_audit_update
AFTER UPDATE ON users
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('UPDATE', 'users', CAST(NEW.user_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('user_id', OLD.user_id, 'full_name', OLD.full_name, 'email', OLD.email, 'role', OLD.role, 'is_active', OLD.is_active),
     JSON_OBJECT('user_id', NEW.user_id, 'full_name', NEW.full_name, 'email', NEW.email, 'role', NEW.role, 'is_active', NEW.is_active),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_users_audit_delete
AFTER DELETE ON users
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('DELETE', 'users', CAST(OLD.user_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('user_id', OLD.user_id, 'full_name', OLD.full_name, 'email', OLD.email, 'role', OLD.role, 'is_active', OLD.is_active),
     NULL,
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_rooms_audit_insert
AFTER INSERT ON rooms
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('INSERT', 'rooms', CAST(NEW.room_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     NULL,
     JSON_OBJECT('room_id', NEW.room_id, 'name', NEW.name, 'building', NEW.building, 'location_details', NEW.location_details, 'capacity', NEW.capacity, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_rooms_audit_update
AFTER UPDATE ON rooms
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('UPDATE', 'rooms', CAST(NEW.room_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('room_id', OLD.room_id, 'name', OLD.name, 'building', OLD.building, 'location_details', OLD.location_details, 'capacity', OLD.capacity, 'status', OLD.status),
     JSON_OBJECT('room_id', NEW.room_id, 'name', NEW.name, 'building', NEW.building, 'location_details', NEW.location_details, 'capacity', NEW.capacity, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_rooms_audit_delete
AFTER DELETE ON rooms
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('DELETE', 'rooms', CAST(OLD.room_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('room_id', OLD.room_id, 'name', OLD.name, 'building', OLD.building, 'location_details', OLD.location_details, 'capacity', OLD.capacity, 'status', OLD.status),
     NULL,
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_items_audit_insert
AFTER INSERT ON items
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('INSERT', 'items', CAST(NEW.item_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     NULL,
     JSON_OBJECT('item_id', NEW.item_id, 'name', NEW.name, 'description', NEW.description, 'category', NEW.category, 'asset_tag', NEW.asset_tag, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_items_audit_update
AFTER UPDATE ON items
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('UPDATE', 'items', CAST(NEW.item_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('item_id', OLD.item_id, 'name', OLD.name, 'description', OLD.description, 'category', OLD.category, 'asset_tag', OLD.asset_tag, 'status', OLD.status),
     JSON_OBJECT('item_id', NEW.item_id, 'name', NEW.name, 'description', NEW.description, 'category', NEW.category, 'asset_tag', NEW.asset_tag, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_items_audit_delete
AFTER DELETE ON items
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('DELETE', 'items', CAST(OLD.item_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('item_id', OLD.item_id, 'name', OLD.name, 'description', OLD.description, 'category', OLD.category, 'asset_tag', OLD.asset_tag, 'status', OLD.status),
     NULL,
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_bookings_audit_insert
AFTER INSERT ON bookings
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('INSERT', 'bookings', CAST(NEW.booking_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     NULL,
     JSON_OBJECT('booking_id', NEW.booking_id, 'user_id', NEW.user_id, 'room_id', NEW.room_id, 'start_time', NEW.start_time, 'end_time', NEW.end_time, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_bookings_audit_update
AFTER UPDATE ON bookings
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('UPDATE', 'bookings', CAST(NEW.booking_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('booking_id', OLD.booking_id, 'user_id', OLD.user_id, 'room_id', OLD.room_id, 'start_time', OLD.start_time, 'end_time', OLD.end_time, 'status', OLD.status),
     JSON_OBJECT('booking_id', NEW.booking_id, 'user_id', NEW.user_id, 'room_id', NEW.room_id, 'start_time', NEW.start_time, 'end_time', NEW.end_time, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_bookings_audit_delete
AFTER DELETE ON bookings
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('DELETE', 'bookings', CAST(OLD.booking_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('booking_id', OLD.booking_id, 'user_id', OLD.user_id, 'room_id', OLD.room_id, 'start_time', OLD.start_time, 'end_time', OLD.end_time, 'status', OLD.status),
     NULL,
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_loans_audit_insert
AFTER INSERT ON loans
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('INSERT', 'loans', CAST(NEW.loan_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     NULL,
     JSON_OBJECT('loan_id', NEW.loan_id, 'user_id', NEW.user_id, 'item_id', NEW.item_id, 'borrowed_at', NEW.borrowed_at, 'due_at', NEW.due_at, 'returned_at', NEW.returned_at, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_loans_audit_update
AFTER UPDATE ON loans
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('UPDATE', 'loans', CAST(NEW.loan_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('loan_id', OLD.loan_id, 'user_id', OLD.user_id, 'item_id', OLD.item_id, 'borrowed_at', OLD.borrowed_at, 'due_at', OLD.due_at, 'returned_at', OLD.returned_at, 'status', OLD.status),
     JSON_OBJECT('loan_id', NEW.loan_id, 'user_id', NEW.user_id, 'item_id', NEW.item_id, 'borrowed_at', NEW.borrowed_at, 'due_at', NEW.due_at, 'returned_at', NEW.returned_at, 'status', NEW.status),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_loans_audit_delete
AFTER DELETE ON loans
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('DELETE', 'loans', CAST(OLD.loan_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('loan_id', OLD.loan_id, 'user_id', OLD.user_id, 'item_id', OLD.item_id, 'borrowed_at', OLD.borrowed_at, 'due_at', OLD.due_at, 'returned_at', OLD.returned_at, 'status', OLD.status),
     NULL,
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

-- audit_lab_notes (migration 003) is the Audit Lab's disposable table.  Its
-- history is recorded exactly like the history of the real tables, so the
-- lab shows the same trigger mechanism that guards bookings and loans.
CREATE OR REPLACE TRIGGER trg_audit_lab_notes_audit_insert
AFTER INSERT ON audit_lab_notes
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('INSERT', 'audit_lab_notes', CAST(NEW.note_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     NULL,
     JSON_OBJECT('note_id', NEW.note_id, 'owner_user_id', NEW.owner_user_id, 'label', NEW.label, 'quantity', NEW.quantity),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_audit_lab_notes_audit_update
AFTER UPDATE ON audit_lab_notes
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('UPDATE', 'audit_lab_notes', CAST(NEW.note_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('note_id', OLD.note_id, 'owner_user_id', OLD.owner_user_id, 'label', OLD.label, 'quantity', OLD.quantity),
     JSON_OBJECT('note_id', NEW.note_id, 'owner_user_id', NEW.owner_user_id, 'label', NEW.label, 'quantity', NEW.quantity),
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));

CREATE OR REPLACE TRIGGER trg_audit_lab_notes_audit_delete
AFTER DELETE ON audit_lab_notes
FOR EACH ROW
INSERT INTO audit_events
    (action, entity_table, entity_id, database_user, application_user_id,
     client_host, connection_id, old_values, new_values, event_source)
VALUES
    ('DELETE', 'audit_lab_notes', CAST(OLD.note_id AS CHAR), USER(),
     (SELECT u.user_id FROM users AS u WHERE u.user_id = @app_user_id),
     SUBSTRING_INDEX(USER(), '@', -1), CONNECTION_ID(),
     JSON_OBJECT('note_id', OLD.note_id, 'owner_user_id', OLD.owner_user_id, 'label', OLD.label, 'quantity', OLD.quantity),
     NULL,
     IF(@app_user_id IS NULL, 'direct_sql', 'application'));
