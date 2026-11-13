-- 02  Cause the events the plugin records.
--
-- Shows:  a successful write through the application's code path, a statement that
--         the server rejects, and what each of them looks like to the plugin.
-- Needs:  01 done; the demo data from database/seed.sql (user alice, 'Room 201').
-- Run with:  mariadb --force -uroot -p < examples/02_cause_events.sql
--            (--force keeps going after the deliberate error below)
-- Then read the result with 03_read_the_log.sql.
--
-- A third event type, a FAILED LOGIN, cannot be produced from inside one SQL
-- session.  Run this from a shell (any wrong password for any account):
--     MYSQL_PWD=wrong mariadb -h127.0.0.1 -unobody_demo -e "SELECT 1"
-- The server answers ERROR 1045 and the plugin writes a connect_failed record.

USE university_resources;

-- (a) A booking, with the application user passed to the row-history trigger the
--     way frontend/app.py does it.  The plugin sees: table_write on bookings, one
--     table_write on audit_events (the trigger's own INSERT, same query_id) and
--     one statement record with error_code 0 and a literal-free digest.
SET @app_user_id = (SELECT user_id FROM users WHERE email = 'alice.student@example.edu');
SET @day = FLOOR(30 + RAND() * 900);          -- random day, so reruns do not collide
INSERT INTO bookings (user_id, room_id, start_time, end_time)
SELECT @app_user_id, room_id,
       CURRENT_DATE + INTERVAL @day DAY + INTERVAL 15 HOUR,
       CURRENT_DATE + INTERVAL @day DAY + INTERVAL 16 HOUR
  FROM rooms WHERE name = 'Room 201';

-- (b) A statement the server rejects: capacity must be > 0 (CHECK constraint).
--     Expected:  ERROR 4025 (23000): CONSTRAINT `chk_rooms_capacity_positive` failed ...
--     The plugin still sees table_write for rooms (TABLE events are raised when the
--     table is opened, BEFORE the statement runs) and then a statement record with
--     "error_code":4025,"status":"error".  A row trigger can never see this: no row
--     was written.  This is the difference between the two audit mechanisms.
INSERT INTO rooms (name, capacity) VALUES ('Broken room', 0);

-- (c) A rolled-back change.  The plugin records the statement with status ok even
--     though the value never became permanent: it observes statements, not commits.
START TRANSACTION;
UPDATE rooms SET capacity = capacity + 1 WHERE name = 'Room 201';
ROLLBACK;
SELECT name, capacity FROM rooms WHERE name = 'Room 201';   -- unchanged
